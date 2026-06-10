import Foundation

/// Parses an agent session transcript (split into lines) into a ``Conversation``.
///
/// Each agent ships one conforming struct (``ClaudeCodeTranscriptParser``,
/// ``CodexTranscriptParser``). Parsers are pure and value-typed: the caller
/// owns reading the file (chunked IO, size caps) and hands over already-split
/// lines, keeping the parsers free of any filesystem dependency. File-backed
/// sources in this package (``TailingTranscriptConversationSource``) do that
/// reading through ``TranscriptFileLineReader``.
///
/// Construct the parser at the call site for the kind you have:
///
/// ```swift
/// let parser: any AgentTranscriptParsing = ClaudeCodeTranscriptParser()
/// let conversation = parser.parse(lines: lines)
/// ```
public protocol AgentTranscriptParsing: Sendable {
    /// The agent kind this parser produces.
    var agentKind: AgentKind { get }

    /// Parses the transcript lines into a structured conversation.
    ///
    /// Implementations tolerate unknown or malformed lines by skipping them
    /// rather than failing, so a partially understood transcript still renders.
    ///
    /// - Parameter lines: The transcript's lines, one JSON object per line.
    /// - Returns: The parsed conversation.
    func parse(lines: [String]) -> Conversation
}
