import CmuxAgentConversation
import Foundation

/// A ``ConversationSource`` that reads and parses one agent transcript from the
/// local filesystem.
///
/// P1 is a one-shot read: ``events`` yields a single ``ConversationEvent/snapshot(_:)``
/// and finishes (no live tailing — that is P3). The transcript path is resolved
/// from a panel's restorable-session snapshot (`kind` + `sessionId` +
/// `workingDirectory`) using the same Claude project-dir encoding and Codex
/// session glob the resume path already relies on.
///
/// The chunked, size-capped file read lives here (not in the pure
/// `CmuxAgentConversation` package) so the model layer stays free of IO.
final class LocalTranscriptConversationSource: ConversationSource {
    /// Caps how much of a transcript is read so a runaway file can't stall the
    /// UI. Generous enough for any realistic agent session.
    private static let maxBytes = 32 * 1024 * 1024

    /// The agent kind, used to select the parser.
    private let agentKind: AgentKind

    /// The resolved transcript file URL, or `nil` if none was found.
    private let transcriptURL: URL?

    /// The agent session id (used to seed an empty conversation if no file).
    private let sessionId: String

    /// Creates a source for a panel's resolved transcript.
    ///
    /// - Parameters:
    ///   - agentKind: The agent kind selecting the parser.
    ///   - sessionId: The agent session id.
    ///   - transcriptURL: The resolved transcript file, if one was found.
    init(agentKind: AgentKind, sessionId: String, transcriptURL: URL?) {
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.transcriptURL = transcriptURL
    }

    var events: AsyncStream<ConversationEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [agentKind, sessionId, transcriptURL] in
                let conversation = Self.readAndParse(
                    agentKind: agentKind,
                    sessionId: sessionId,
                    transcriptURL: transcriptURL
                )
                continuation.yield(.snapshot(conversation))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func snapshot() async -> Conversation {
        await Task.detached(priority: .userInitiated) { [agentKind, sessionId, transcriptURL] in
            Self.readAndParse(agentKind: agentKind, sessionId: sessionId, transcriptURL: transcriptURL)
        }.value
    }

    /// Reads the transcript file (chunked, size-capped) and parses it.
    private static func readAndParse(
        agentKind: AgentKind,
        sessionId: String,
        transcriptURL: URL?
    ) -> Conversation {
        guard let transcriptURL else {
            return Conversation.empty(agentKind: agentKind, sessionId: sessionId)
        }
        let lines = readLines(url: transcriptURL, maxBytes: maxBytes)
        let parser = makeParser(for: agentKind)
        return parser.parse(lines: lines)
    }

    /// Constructs the parser for the given kind.
    private static func makeParser(for agentKind: AgentKind) -> any AgentTranscriptParsing {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser()
        case .claudeCode, .unknown:
            return ClaudeCodeTranscriptParser()
        }
    }

    /// Reads a `.jsonl` file into lines using a chunked newline reader with an
    /// oversized-line guard, ported from the app's `forEachJSONLine` loop so the
    /// parser package needs no filesystem dependency.
    private static func readLines(url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var lines: [String] = []
        var leftover = Data()
        var totalRead = 0
        let chunkSize = 64 * 1024
        // Skip a single line longer than this so one pathological line (e.g. a
        // huge embedded blob) can't blow up memory; matches the app's guard.
        let maxLineBytes = 8 * 1024 * 1024

        while totalRead < maxBytes {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let newline = leftover.firstIndex(of: 0x0a) {
                let lineData = leftover.subdata(in: leftover.startIndex..<newline)
                leftover.removeSubrange(leftover.startIndex...newline)
                if lineData.isEmpty || lineData.count > maxLineBytes { continue }
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }
        if !leftover.isEmpty, leftover.count <= maxLineBytes,
           let line = String(data: leftover, encoding: .utf8) {
            lines.append(line)
        }
        return lines
    }
}
