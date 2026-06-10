public import Foundation

/// A live ``ConversationSource`` that tails one agent transcript file.
///
/// On subscription it yields an initial ``ConversationEvent/snapshot(_:)``,
/// then watches the file (``TranscriptFileWatcher``) and reparses it on every
/// change. Each reparse is diffed against the previous parse
/// (``ConversationDelta``): appends and in-place revisions are emitted as
/// ``ConversationEvent/upsert(_:seq:)``, while truncation or rewrite emits
/// ``ConversationEvent/truncated`` followed by a fresh snapshot. Re-read cost
/// is bounded by the same chunked, size-capped reader the one-shot source uses
/// (``TranscriptFileLineReader``), and kqueue coalescing bounds how often the
/// re-read runs.
///
/// ```swift
/// let source = TailingTranscriptConversationSource(
///     agentKind: .claudeCode,
///     sessionId: "sess-1",
///     transcriptURL: url
/// )
/// for await event in source.events { ... }
/// ```
public final class TailingTranscriptConversationSource: ConversationSource {
    /// The agent kind, used to select the parser.
    private let agentKind: AgentKind

    /// The agent session id (used to seed an empty conversation if no file).
    private let sessionId: String

    /// The transcript file to tail, or `nil` if none was found (the source
    /// then yields one empty snapshot and finishes).
    private let transcriptURL: URL?

    /// The bounded reader used for every (re)read.
    private let reader: TranscriptFileLineReader

    /// Creates a tailing source for a resolved transcript.
    ///
    /// - Parameters:
    ///   - agentKind: The agent kind selecting the parser.
    ///   - sessionId: The agent session id.
    ///   - transcriptURL: The transcript file to tail, if one was found.
    ///   - maxBytes: The per-read size cap. Defaults to 32 MiB, generous
    ///     enough for any realistic agent session.
    public init(
        agentKind: AgentKind,
        sessionId: String,
        transcriptURL: URL?,
        maxBytes: Int = 32 * 1024 * 1024
    ) {
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.transcriptURL = transcriptURL
        self.reader = TranscriptFileLineReader(maxBytes: maxBytes)
    }

    public var events: AsyncStream<ConversationEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                await tail(into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func snapshot() async -> Conversation {
        await Task.detached(priority: .userInitiated) { [self] in
            readAndParse()
        }.value
    }

    /// Emits the initial snapshot, then re-reads and diffs on every file
    /// change until the consuming task is cancelled.
    private func tail(into continuation: AsyncStream<ConversationEvent>.Continuation) async {
        guard let transcriptURL else {
            continuation.yield(.snapshot(Conversation.empty(agentKind: agentKind, sessionId: sessionId)))
            continuation.finish()
            return
        }

        // Attach the watcher before the initial read so a write that lands
        // mid-read is buffered as a pending signal instead of being missed.
        let changes = TranscriptFileWatcher(url: transcriptURL).changes()

        var current = readAndParse()
        var seq = current.seq
        continuation.yield(.snapshot(current))

        for await _ in changes {
            if Task.isCancelled { break }
            let fresh = readAndParse()
            switch ConversationDelta.compute(from: current, to: fresh) {
            case .unchanged:
                continue
            case let .appendedOrChanged(messages):
                seq = max(seq, fresh.seq) + 1
                current = Self.stamped(fresh, seq: seq)
                continuation.yield(.upsert(messages, seq: seq))
            case .truncated:
                seq = max(seq, fresh.seq) + 1
                current = Self.stamped(fresh, seq: seq)
                continuation.yield(.truncated)
                continuation.yield(.snapshot(current))
            }
        }
        continuation.finish()
    }

    /// Reads the transcript (chunked, size-capped) and parses it.
    private func readAndParse() -> Conversation {
        guard let transcriptURL else {
            return Conversation.empty(agentKind: agentKind, sessionId: sessionId)
        }
        let lines = reader.readLines(url: transcriptURL)
        return makeParser().parse(lines: lines)
    }

    /// Constructs the parser for this source's agent kind.
    private func makeParser() -> any AgentTranscriptParsing {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser()
        case .claudeCode, .unknown:
            return ClaudeCodeTranscriptParser()
        }
    }

    /// Returns the conversation re-stamped with a monotonic emission `seq`,
    /// so consumers (and view scroll-follow logic) see every applied change.
    private static func stamped(_ conversation: Conversation, seq: UInt64) -> Conversation {
        Conversation(
            id: conversation.id,
            agentKind: conversation.agentKind,
            sessionId: conversation.sessionId,
            messages: conversation.messages,
            seq: seq
        )
    }
}
