import Foundation

/// Carries one tool invocation or paired tool result.
public struct ToolRunPayload: Codable, Hashable, Sendable {
    /// The tool name reported by the agent runtime.
    public let toolName: String
    /// A compact summary of the tool arguments.
    public let argumentSummary: String
    /// A compact summary of the tool result, when known.
    public let resultSummary: String?
    /// Whether the tool represents a terminal or shell command.
    public let isTerminal: Bool
    /// The tool exit code, when reported.
    public let exitCode: Int?
    /// Whether the tool is still running.
    public let isRunning: Bool
    /// Runtime correlation identifier, when reported.
    public let toolCallID: String?
    /// Bounded full input rendering for a detail surface.
    public let inputDetail: String?
    /// Shell command text for terminal tools.
    public let command: String?
    /// Bounded captured output for a detail surface.
    public let output: String?
    /// Wall-clock duration in seconds, when reported.
    public let durationSeconds: Double?
    /// Runtime lifecycle status, retained as a fail-open string.
    public let status: String?

    private enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case argumentSummary = "argument_summary"
        case resultSummary = "result_summary"
        case isTerminal = "is_terminal"
        case exitCode = "exit_code"
        case isRunning = "is_running"
        case toolCallID = "tool_call_id"
        case inputDetail = "input_detail"
        case command
        case output
        case durationSeconds = "duration_seconds"
        case status
    }

    /// Creates a tool run payload.
    /// - Parameters:
    ///   - toolName: The tool name reported by the agent runtime.
    ///   - argumentSummary: A compact summary of the tool arguments.
    ///   - resultSummary: A compact summary of the tool result, when known.
    ///   - isTerminal: Whether the tool represents a terminal or shell command.
    ///   - exitCode: The tool exit code, when reported.
    ///   - isRunning: Whether the tool is still running.
    public init(
        toolName: String,
        argumentSummary: String,
        resultSummary: String? = nil,
        isTerminal: Bool,
        exitCode: Int? = nil,
        isRunning: Bool,
        toolCallID: String? = nil,
        inputDetail: String? = nil,
        command: String? = nil,
        output: String? = nil,
        durationSeconds: Double? = nil,
        status: String? = nil
    ) {
        self.toolName = toolName
        self.argumentSummary = argumentSummary
        self.resultSummary = resultSummary
        self.isTerminal = isTerminal
        self.exitCode = exitCode
        self.isRunning = isRunning
        self.toolCallID = toolCallID
        self.inputDetail = inputDetail
        self.command = command
        self.output = output
        self.durationSeconds = durationSeconds
        self.status = status
    }
}
