import Foundation

/// A request by the agent to invoke a tool, captured verbatim from the transcript.
///
/// The call is stored separately from its result: ``ToolResult`` references
/// this value by ``ToolUse/id``. Pairing call and result into a single row is a
/// view-projection concern, not a model concern, so the model preserves both
/// nodes and the correlating id.
public struct ToolUse: Codable, Hashable, Sendable, Identifiable {
    /// The agent-assigned call id (Claude `tool_use.id`, Codex `call_id`).
    /// ``ToolResult/toolUseID`` points back to this value.
    public let id: String

    /// The tool's name (e.g. `Bash`, `Read`, `exec_command`).
    public let name: String

    /// The raw JSON arguments the agent passed, as a string. Kept unparsed so
    /// the model stays schema-agnostic; the UI can pretty-print on demand.
    public let inputJSON: String

    /// A short, human-readable one-line summary of the call (e.g. the shell
    /// command), or `nil` when no concise summary is available.
    public let inputSummary: String?

    /// Creates a tool-use node.
    ///
    /// - Parameters:
    ///   - id: The agent-assigned call id used to correlate the result.
    ///   - name: The tool's name.
    ///   - inputJSON: The raw JSON arguments as a string.
    ///   - inputSummary: An optional concise one-line summary of the input.
    public init(id: String, name: String, inputJSON: String, inputSummary: String? = nil) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        self.inputSummary = inputSummary
    }
}
