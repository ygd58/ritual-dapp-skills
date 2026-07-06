// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RagAgent
/// @notice On-chain RAG (Retrieval-Augmented Generation) agent for Ritual Chain.
///         Fetches a document via HTTP precompile (0x0801), then answers a question
///         about it using the LLM precompile (0x0802). Both the document and the
///         answer are stored on-chain.
/// @dev Two-step async flow: fetchDoc() then askQuestion(). One async tx per sender.
contract RagAgent {
    address public immutable HTTP_PRECOMPILE;
    address public immutable LLM_PRECOMPILE;
    address constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;

    constructor(address _http, address _llm) {
        HTTP_PRECOMPILE = _http == address(0) ? address(0x0801) : _http;
        LLM_PRECOMPILE  = _llm  == address(0) ? address(0x0802) : _llm;
    }

    struct Query {
        address submitter;
        string  docUrl;
        string  question;
        bytes   docContent;
        string  answer;
        bool    answered;
        uint256 submittedAt;
        uint256 answeredAt;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    uint256 public nextQueryId = 1;
    mapping(uint256 => Query) public queries;

    event QuerySubmitted(uint256 indexed queryId, address indexed submitter, string docUrl, string question);
    event DocFetched(uint256 indexed queryId, uint256 docLength);
    event AnswerReady(uint256 indexed queryId, string answer);

    error QueryNotFound(uint256 queryId);
    error AlreadyAnswered(uint256 queryId);
    error DocNotFetched(uint256 queryId);
    error HTTPFailed();
    error LLMFailed(string reason);
    error InvalidInput();

    function depositFees(uint256 lockDuration) external payable {
        (bool ok,) = RITUAL_WALLET.call{value: msg.value}(
            abi.encodeWithSignature("deposit(uint256)", lockDuration)
        );
        require(ok, "deposit failed");
    }

    /// @notice Submit a document URL and a question about it.
    function submitQuery(
        string calldata docUrl,
        string calldata question
    ) external returns (uint256 queryId) {
        if (bytes(docUrl).length == 0 || bytes(question).length == 0) revert InvalidInput();

        queryId = nextQueryId++;
        queries[queryId] = Query({
            submitter:   msg.sender,
            docUrl:      docUrl,
            question:    question,
            docContent:  "",
            answer:      "",
            answered:    false,
            submittedAt: block.number,
            answeredAt:  0
        });

        emit QuerySubmitted(queryId, msg.sender, docUrl, question);
    }

    /// @notice Step 1: Fetch the document via HTTP precompile.
    function fetchDoc(
        uint256 queryId,
        address executor,
        uint64  ttl
    ) external {
        Query storage q = queries[queryId];
        if (q.submitter == address(0)) revert QueryNotFound(queryId);
        if (q.answered) revert AlreadyAnswered(queryId);

        bytes memory httpInput = abi.encode(
            executor,
            q.docUrl,
            uint8(0),
            new string[](0),
            new string[](0),
            bytes(""),
            ttl == 0 ? uint64(300) : ttl
        );

        (bool ok, bytes memory result) = HTTP_PRECOMPILE.call(httpInput);
        if (!ok) revert HTTPFailed();

        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));
        q.docContent = actualOutput;

        emit DocFetched(queryId, actualOutput.length);
    }

    /// @notice Step 2: Ask the question using LLM precompile.
    function askQuestion(
        uint256 queryId,
        address executor,
        uint64  ttl
    ) external {
        Query storage q = queries[queryId];
        if (q.submitter == address(0)) revert QueryNotFound(queryId);
        if (q.answered) revert AlreadyAnswered(queryId);
        if (q.docContent.length == 0) revert DocNotFetched(queryId);

        _runLlm(queryId, executor, ttl);
    }

    function _runLlm(uint256 queryId, address executor, uint64 ttl) internal {
        Query storage q = queries[queryId];

        (bool ok, bytes memory result) = LLM_PRECOMPILE.call(
            _buildLlmInput(executor, _buildMessages(q.question, q.docContent), ttl)
        );
        if (!ok) revert LLMFailed("precompile call failed");

        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));

        (bool hasError, bytes memory completionData, , string memory errorMessage,) =
            abi.decode(actualOutput, (bool, bytes, bytes, string, ConvoHistory));

        if (hasError) revert LLMFailed(errorMessage);

        q.answer    = string(completionData);
        q.answered  = true;
        q.answeredAt = block.number;

        emit AnswerReady(queryId, q.answer);
    }

    function _buildMessages(string memory question, bytes memory docContent) internal pure returns (string memory) {
        return string.concat(
            "[{\"role\":\"system\",\"content\":\"You are a document assistant. Answer questions based only on the provided document. Be concise and accurate.\"},",
            "{\"role\":\"user\",\"content\":\"Document:\\n",
            string(docContent),
            "\\n\\nQuestion: ",
            question,
            "\"}]"
        );
    }

    function _buildLlmInput(address executor, string memory messages, uint64 ttl) internal pure returns (bytes memory) {
        return abi.encode(
            executor,
            new bytes[](0),
            uint256(ttl == 0 ? 300 : ttl),
            new bytes[](0),
            bytes(""),
            messages,
            "zai-org/GLM-4.7-FP8",
            int256(0), "", false, int256(2048), "", "",
            uint256(1), false, int256(0), "low", bytes(""),
            int256(-1), "", "", false, int256(300),
            bytes(""), bytes(""), int256(-1), int256(1000), "",
            false,
            abi.encode("", "", "")
        );
    }

    function getQuery(uint256 queryId) external view returns (Query memory) {
        if (queries[queryId].submitter == address(0)) revert QueryNotFound(queryId);
        return queries[queryId];
    }

    function getAnswer(uint256 queryId) external view returns (string memory) {
        if (queries[queryId].submitter == address(0)) revert QueryNotFound(queryId);
        return queries[queryId].answer;
    }

    receive() external payable {}
}
