/// A non-terminal tool invocation by the agent (file read, search, web
/// fetch, subagent, ...), paired with its result when one has arrived.
public struct ChatToolUse: Sendable, Equatable, Codable {
    /// Lifecycle of a tool invocation.
    public enum Status: String, Sendable, Equatable, Codable {
        /// The tool was invoked and no result has been observed yet.
        case running
        /// The tool finished successfully.
        case succeeded
        /// The tool finished with an error result.
        case failed
    }

    /// The tool's machine name as the agent reported it (e.g. `Read`).
    public let toolName: String

    /// A one-line human-readable summary of the invocation, built by the
    /// transcript parser (e.g. `Read src/main.swift`).
    public let summary: String

    /// The full tool input rendered as text for detail surfaces.
    public let inputDetail: String?

    /// The tool result rendered as text, when one has arrived. Truncated at
    /// the producing side; renderers offer the terminal escape hatch for the
    /// full output.
    public let output: String?

    /// Current lifecycle state of the invocation.
    public let status: Status

    /// Absolute paths referenced by the tool input, when the parser can infer them.
    public let referencedPaths: [String]?

    /// Creates a tool invocation record.
    ///
    /// - Parameters:
    ///   - toolName: Machine name of the tool.
    ///   - summary: One-line human-readable invocation summary.
    ///   - inputDetail: Full input text for detail surfaces.
    ///   - output: Result text, when one has arrived.
    ///   - status: Lifecycle state of the invocation.
    ///   - referencedPaths: Absolute paths referenced by the tool input.
    public init(
        toolName: String,
        summary: String,
        inputDetail: String? = nil,
        output: String? = nil,
        status: Status = .running,
        referencedPaths: [String]? = nil
    ) {
        self.toolName = toolName
        self.summary = summary
        self.inputDetail = inputDetail
        self.output = output
        self.status = status
        self.referencedPaths = referencedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case summary
        case inputDetail = "input_detail"
        case output
        case status
        case referencedPaths = "referenced_paths"
    }
}
