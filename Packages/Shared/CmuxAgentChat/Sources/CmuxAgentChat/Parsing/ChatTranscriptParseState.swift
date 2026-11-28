import Foundation

/// Carry-over state between incremental transcript parse calls.
///
/// Agent transcripts are tailed: a tool invocation and its result can land
/// in different parse calls. The state carries the registry of tool
/// invocations still awaiting a result so a later call can pair them, plus
/// the last seen timestamp for lines that omit one. Pass the state returned
/// by one ``ClaudeTranscriptParser/parse(lines:startingSeq:state:)`` or
/// ``CodexTranscriptParser/parse(lines:startingSeq:state:)`` call into the
/// next.
public struct ChatTranscriptParseState: Sendable, Equatable, Codable {
    /// Tool invocations awaiting a result, keyed by the transcript's tool
    /// call identifier (`tool_use_id` for Claude, `call_id` for Codex).
    ///
    /// Each value is the already-emitted message in its running form; when
    /// the result line arrives the parser re-emits a completed copy through
    /// ``ChatTranscriptParseResult/updatedMessages``.
    public var pendingToolUses: [String: [ChatMessage]]

    /// Timestamp of the last line that carried one, used as the fallback
    /// for subsequent lines that omit a timestamp.
    public var lastTimestamp: Date?

    /// Creates parse carry-over state.
    ///
    /// - Parameters:
    ///   - pendingToolUses: Tool invocations awaiting a result, keyed by
    ///     tool call identifier.
    ///   - lastTimestamp: Timestamp fallback for lines without one.
    public init(pendingToolUses: [String: [ChatMessage]] = [:], lastTimestamp: Date? = nil) {
        self.pendingToolUses = pendingToolUses
        self.lastTimestamp = lastTimestamp
    }

    private enum CodingKeys: String, CodingKey {
        case pendingToolUses = "pending_tool_uses"
        case lastTimestamp = "last_timestamp"
    }
}
