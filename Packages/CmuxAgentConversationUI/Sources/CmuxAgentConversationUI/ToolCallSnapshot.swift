import Foundation

/// An immutable value describing a tool call paired with its result.
///
/// The view model pairs a ``CmuxAgentConversation/ToolUse`` with the
/// ``CmuxAgentConversation/ToolResult`` that shares its id, so the row can show
/// the call and (when present) its output as one collapsible unit. `resultText`
/// is `nil` while a call is still pending (no result line yet).
public struct ToolCallSnapshot: Hashable, Sendable {
    /// The correlating call id (`tool_use_id` / `call_id`).
    public let callID: String

    /// The tool's name (e.g. `Bash`, `exec_command`).
    public let name: String

    /// A short one-line summary of the input (e.g. the shell command), if any.
    public let inputSummary: String?

    /// The raw JSON input, shown when the row is expanded.
    public let inputJSON: String

    /// The flattened result text, or `nil` if the result has not arrived.
    public let resultText: String?

    /// Whether the tool reported an error.
    public let isError: Bool

    /// Creates a tool-call snapshot.
    ///
    /// - Parameters:
    ///   - callID: The correlating call id.
    ///   - name: The tool's name.
    ///   - inputSummary: A short one-line summary of the input, if any.
    ///   - inputJSON: The raw JSON input.
    ///   - resultText: The flattened result text, or `nil` if pending.
    ///   - isError: Whether the tool reported an error.
    public init(
        callID: String,
        name: String,
        inputSummary: String?,
        inputJSON: String,
        resultText: String?,
        isError: Bool
    ) {
        self.callID = callID
        self.name = name
        self.inputSummary = inputSummary
        self.inputJSON = inputJSON
        self.resultText = resultText
        self.isError = isError
    }
}
