import Foundation

/// An in-memory ``ChatEventSource`` for previews, tests, and demo mode.
///
/// Serves a scripted backlog through paged history, echoes sends back as
/// transcript messages (with a short scripted agent reply), and exposes
/// ``emit(_:)`` so tests can drive arbitrary event sequences.
public actor FixtureChatEventSource: ChatEventSource {
    private var backlog: [ChatMessage]
    private var nextSeq: Int
    private var continuations: [Int: AsyncStream<ChatSessionEvent>.Continuation] = [:]
    private var continuationCounter = 0
    private let replyToSends: Bool
    /// When true the source serves a terminal command-block backlog/history
    /// instead of message history, for the terminal-chat demo and tests.
    private let isTerminal: Bool
    private var terminalBacklog: [TerminalCommandBlock]
    /// What terminal history reports for `hasMore` (to exercise the store's
    /// force-no-paging rule for terminal sessions).
    private let terminalHasMore: Bool

    /// Creates a fixture source.
    ///
    /// - Parameters:
    ///   - backlog: The scripted transcript, ordered by ascending seq.
    ///   - replyToSends: When `true`, every ``send(text:attachments:sessionID:)``
    ///     echoes the prompt and emits a canned agent reply, so the demo
    ///     conversation stays alive.
    public init(backlog: [ChatMessage] = [], replyToSends: Bool = false) {
        self.backlog = backlog
        self.nextSeq = (backlog.last?.seq ?? -1) + 1
        self.replyToSends = replyToSends
        self.isTerminal = false
        self.terminalBacklog = []
        self.terminalHasMore = false
    }

    /// Creates a terminal-mode fixture serving a command-block backlog.
    ///
    /// - Parameters:
    ///   - terminalBacklog: Scripted command blocks, oldest first.
    ///   - terminalHasMore: What history reports for `hasMore`.
    public init(terminalBacklog: [TerminalCommandBlock], terminalHasMore: Bool = false) {
        self.backlog = []
        self.nextSeq = 0
        self.replyToSends = false
        self.isTerminal = true
        self.terminalBacklog = terminalBacklog
        self.terminalHasMore = terminalHasMore
    }

    /// Emits terminal command-block deltas to live subscribers (test/demo).
    ///
    /// - Parameter blocks: Whole-value blocks; receivers upsert by id.
    public func emitTerminalBlocks(_ blocks: [TerminalCommandBlock]) {
        emit(.terminalBlocks(blocks))
    }

    public func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        if isTerminal {
            return ChatHistoryPage(messages: [], hasMore: terminalHasMore, terminalBlocks: terminalBacklog)
        }
        let eligible: [ChatMessage]
        if let beforeSeq {
            eligible = backlog.filter { $0.seq < beforeSeq }
        } else {
            eligible = backlog
        }
        let page = Array(eligible.suffix(limit))
        let hasMore = eligible.count > page.count
        return ChatHistoryPage(messages: page, hasMore: hasMore)
    }

    public func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let id = continuationCounter
        continuationCounter += 1
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    public func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        // A real terminal echoes the typed command back as a command BLOCK
        // (via the PTY), not as a transcript message; tests/demo drive that
        // with emitTerminalBlocks, so don't fake a message echo here.
        if isTerminal { return }
        var appended: [ChatMessage] = []
        for _ in attachments {
            appended.append(
                makeMessage(role: .user, kind: .attachment(ChatAttachment(media: .image)))
            )
        }
        if !text.isEmpty {
            appended.append(makeMessage(role: .user, kind: .prose(ChatProse(text: text))))
        }
        emit(.appended(appended))
        guard replyToSends else { return }
        emit(.stateChanged(.working(since: Date())))
        let reply = makeMessage(
            role: .agent,
            kind: .prose(ChatProse(text: "Echoing your prompt: *\(text)*"))
        )
        emit(.appended([reply]))
        emit(.stateChanged(.idle))
    }

    public func interrupt(sessionID: String, hard: Bool) async throws {
        emit(.appended([
            makeMessage(
                role: .system,
                kind: .status(ChatStatusTransition(event: .interrupted))
            ),
        ]))
        emit(.stateChanged(.idle))
    }

    public func answer(optionIndex: Int, sessionID: String) async throws {
        emit(.stateChanged(.working(since: Date())))
    }

    /// Pushes an event to every live subscriber and folds appended or
    /// updated messages into the backlog so later history reads see them.
    ///
    /// - Parameter event: The event to deliver.
    public func emit(_ event: ChatSessionEvent) {
        switch event {
        case .appended(let messages):
            backlog.append(contentsOf: messages)
            nextSeq = max(nextSeq, (messages.last?.seq ?? -1) + 1)
        case .updated(let messages):
            for message in messages {
                if let index = backlog.firstIndex(where: { $0.id == message.id }) {
                    backlog[index] = message
                }
            }
        case .terminalBlocks(let blocks):
            for block in blocks {
                if let index = terminalBacklog.firstIndex(where: { $0.id == block.id }) {
                    terminalBacklog[index] = block
                } else {
                    terminalBacklog.append(block)
                }
            }
        case .reset:
            backlog = []
            terminalBacklog = []
        case .unknown:
            break
        case .stateChanged, .descriptorChanged:
            break
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Ends all live event streams, as a dropped connection would.
    public func finishStreams() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ id: Int) {
        continuations[id] = nil
    }

    private func makeMessage(role: ChatRole, kind: ChatMessageKind) -> ChatMessage {
        let seq = nextSeq
        nextSeq += 1
        return ChatMessage(
            id: "fixture-\(seq)",
            seq: seq,
            role: role,
            timestamp: Date(),
            kind: kind
        )
    }
}
