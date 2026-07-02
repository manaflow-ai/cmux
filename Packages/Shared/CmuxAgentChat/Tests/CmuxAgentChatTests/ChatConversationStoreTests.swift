import Foundation
import Testing

@testable import CmuxAgentChat

/// Bounded polling for store state driven by async event delivery.
///
/// The store applies events on the main actor after actor hops through the
/// event source, so tests poll with cooperative yields (plus a tiny periodic
/// sleep as a scheduler pressure valve) instead of racing a fixed await.
@MainActor
private enum TestPoller {
    static func waitUntil(
        iterations: Int = 400,
        _ condition: () -> Bool
    ) async -> Bool {
        for iteration in 0..<iterations {
            if condition() { return true }
            await Task.yield()
            if iteration % 20 == 19 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return condition()
    }
}

/// A `ChatEventSource` whose `send` fails a configurable number of times
/// before succeeding; never echoes anything back.
private actor FailingChatEventSource: ChatEventSource {
    struct SendError: Error {}

    private var failuresRemaining: Int

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        ChatHistoryPage(messages: [], hasMore: false)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SendError()
        }
    }

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}
}

/// A `ChatEventSource` whose `send` suspends until released, so tests can
/// observe the optimistic `.sending` state deterministically.
private actor GatedChatEventSource: ChatEventSource {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        ChatHistoryPage(messages: [], hasMore: false)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}
}

/// A `ChatEventSource` whose `send` succeeds without echoing, with a
/// manual `emit` so tests control the transcript echo's exact shape.
private actor SilentSendEventSource: ChatEventSource {
    struct SendError: Error {}

    private var continuation: AsyncStream<ChatSessionEvent>.Continuation?
    private var failSends = false

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        ChatHistoryPage(messages: [], hasMore: false)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { self.continuation = $0 }
    }

    func emit(_ event: ChatSessionEvent) {
        continuation?.yield(event)
    }

    func setSendFailure(_ fail: Bool) {
        failSends = fail
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        if failSends { throw SendError() }
    }

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}
}

/// A `ChatEventSource` modeling the Mac tailer's bounded cache: the
/// newest page is served, but paging before it returns an empty page that
/// still reports `hasMore` (older transcript exists on disk only).
private actor TruncatedHeadEventSource: ChatEventSource {
    private let newest: [ChatMessage]

    init(newest: [ChatMessage]) {
        self.newest = newest
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        if let beforeSeq {
            let eligible = newest.filter { $0.seq < beforeSeq }
            return ChatHistoryPage(messages: Array(eligible.suffix(limit)), hasMore: true)
        }
        return ChatHistoryPage(messages: Array(newest.suffix(limit)), hasMore: true)
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { $0.finish() }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {}

    func interrupt(sessionID: String, hard: Bool) async throws {}

    func answer(optionIndex: Int, sessionID: String) async throws {}
}

@Suite("ChatConversationStore")
@MainActor
struct ChatConversationStoreTests {
    // MARK: - Fixtures

    private static nonisolated let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    private static func descriptor() -> ChatSessionDescriptor {
        ChatSessionDescriptor(id: "session-1", agentKind: .claude, title: "Test")
    }

    private static func prose(
        seq: Int,
        role: ChatRole = .agent,
        text: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: role,
            timestamp: baseTime.addingTimeInterval(TimeInterval(seq)),
            kind: .prose(ChatProse(text: text ?? "text \(seq)"))
        )
    }

    private static func backlog(count: Int) -> [ChatMessage] {
        (0..<count).map { prose(seq: $0) }
    }

    /// A live streaming-preview message: agent prose with a stable synthetic id
    /// and a high seq so it sorts after the committed window, matching what the
    /// host's prose streamer emits.
    private static func streamingMessage(text: String) -> ChatMessage {
        ChatMessage(
            id: "stream:session-1",
            seq: Int.max - 1,
            role: .agent,
            timestamp: baseTime.addingTimeInterval(1000),
            kind: .prose(ChatProse(text: text))
        )
    }

    private static func makeStore(
        source: any ChatEventSource,
        lastReadSeq: Int? = nil,
        pageSize: Int = 10,
        maxWindowCount: Int = 600
    ) -> ChatConversationStore {
        ChatConversationStore(
            descriptor: descriptor(),
            source: source,
            lastReadSeq: lastReadSeq,
            pageSize: pageSize,
            maxWindowCount: maxWindowCount,
            now: { baseTime }
        )
    }

    private static func snapshots(_ rows: [ChatTranscriptRow]) -> [ChatMessageRowSnapshot] {
        rows.compactMap {
            if case .message(let snapshot) = $0 { return snapshot }
            return nil
        }
    }

    private static func pendingItems(_ rows: [ChatTranscriptRow]) -> [ChatPendingOutbound] {
        rows.compactMap {
            if case .pendingOutbound(let item) = $0 { return item }
            return nil
        }
    }

    private static func userProseTexts(_ rows: [ChatTranscriptRow]) -> [String] {
        snapshots(rows).compactMap { snapshot in
            guard snapshot.message.role == .user,
                  case .prose(let prose) = snapshot.message.kind else { return nil }
            return prose.text
        }
    }

    // MARK: - Initial history

    @Test("initial load populates rows; small backlog has no more history")
    func initialLoadSmallBacklog() async {
        let source = FixtureChatEventSource(backlog: Self.backlog(count: 4))
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })
        let snaps = Self.snapshots(store.rows)
        #expect(snaps.map(\.message.seq) == [0, 1, 2, 3])
        #expect(store.hasMoreHistory == false)
    }

    @Test("initial load with backlog beyond pageSize keeps the newest page and flags more history")
    func initialLoadLargeBacklog() async {
        let source = FixtureChatEventSource(backlog: Self.backlog(count: 15))
        let store = Self.makeStore(source: source, pageSize: 10)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })
        let snaps = Self.snapshots(store.rows)
        #expect(snaps.count == 10)
        #expect(snaps.first?.message.seq == 5)
        #expect(snaps.last?.message.seq == 14)
        #expect(store.hasMoreHistory == true)
    }

    // MARK: - Live stream

    @Test("run applies appended events from the live stream")
    func liveAppend() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        await source.emit(.appended([Self.prose(seq: 0, text: "live one")]))
        await source.emit(.appended([Self.prose(seq: 1, text: "live two")]))

        #expect(await TestPoller.waitUntil { Self.snapshots(store.rows).count == 2 })
        let snaps = Self.snapshots(store.rows)
        #expect(snaps.map(\.message.seq) == [0, 1])
    }

    @Test("updated event replaces a message in place")
    func updatedReplacesInPlace() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        let original = Self.prose(seq: 0, text: "original")
        await source.emit(.appended([original]))
        #expect(await TestPoller.waitUntil { Self.snapshots(store.rows).count == 1 })

        let revised = ChatMessage(
            id: original.id,
            seq: original.seq,
            role: original.role,
            timestamp: original.timestamp,
            kind: .toolUse(
                ChatToolUse(toolName: "Read", summary: "Read file", status: .succeeded)
            )
        )
        await source.emit(.updated([revised]))

        #expect(
            await TestPoller.waitUntil {
                Self.snapshots(store.rows).first?.message.kind == revised.kind
            }
        )
        let snaps = Self.snapshots(store.rows)
        #expect(snaps.count == 1)
        #expect(snaps.first?.message.id == original.id)
    }

    @Test("streaming prose renders as a trailing bubble and clears on nil")
    func streamingProseRendersAndClears() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        let preview = Self.streamingMessage(text: "partial answer")
        await source.emit(.streamingProse(preview))
        #expect(
            await TestPoller.waitUntil {
                Self.snapshots(store.rows).contains { $0.message.id == preview.id }
            }
        )
        await source.emit(.streamingProse(nil))
        #expect(
            await TestPoller.waitUntil {
                !Self.snapshots(store.rows).contains { $0.message.id == preview.id }
            }
        )
    }

    @Test("authoritative agent prose supersedes the live preview without a duplicate")
    func authoritativeProseSupersedesPreview() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        let preview = Self.streamingMessage(text: "The sky is blue")
        await source.emit(.streamingProse(preview))
        #expect(
            await TestPoller.waitUntil {
                Self.snapshots(store.rows).contains { $0.message.id == preview.id }
            }
        )
        // The committed transcript line lands; the preview must vanish and only
        // the real message remains (no duplicate bubble).
        let committed = Self.prose(seq: 0, role: .agent, text: "The sky is blue")
        await source.emit(.appended([committed]))
        #expect(
            await TestPoller.waitUntil {
                let snaps = Self.snapshots(store.rows)
                return snaps.contains { $0.message.id == committed.id }
                    && !snaps.contains { $0.message.id == preview.id }
            }
        )
        let proseTexts = Self.snapshots(store.rows)
            .filter { $0.message.role == .agent }
            .compactMap { snapshot -> String? in
                if case .prose(let prose) = snapshot.message.kind { return prose.text }
                return nil
            }
        #expect(proseTexts == ["The sky is blue"])
    }

    @Test("stateChanged event updates agentState")
    func stateChangedUpdatesAgentState() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        #expect(store.agentState == .idle)
        let state = ChatAgentState.working(since: Self.baseTime)
        await source.emit(.stateChanged(state))
        #expect(await TestPoller.waitUntil { store.agentState == state })
    }

    @Test("appends beyond maxWindowCount trim the window and re-open history")
    func windowCapTrims() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source, maxWindowCount: 10)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        await source.emit(.appended((0..<15).map { Self.prose(seq: $0) }))

        #expect(await TestPoller.waitUntil { Self.snapshots(store.rows).count == 10 })
        let snaps = Self.snapshots(store.rows)
        #expect(snaps.first?.message.seq == 5)
        #expect(snaps.last?.message.seq == 14)
        #expect(store.hasMoreHistory == true)
    }

    // MARK: - Send pipeline

    @Test("send shows an optimistic .sending row, then .delivered")
    func sendOptimisticDeliveryStates() async {
        let source = GatedChatEventSource()
        let store = Self.makeStore(source: source)

        let sendTask = Task { await store.send(text: "gated prompt") }
        #expect(
            await TestPoller.waitUntil {
                Self.pendingItems(store.rows).first?.delivery == .sending
            }
        )
        #expect(Self.pendingItems(store.rows).first?.text == "gated prompt")

        await source.release()
        await sendTask.value
        #expect(Self.pendingItems(store.rows).first?.delivery == .delivered)
    }

    @Test("the fixture echo reconciles the pending row into a real user message")
    func sendEchoReconcilesPending() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        await store.send(text: "hello agent")

        #expect(
            await TestPoller.waitUntil {
                Self.pendingItems(store.rows).isEmpty
                    && Self.userProseTexts(store.rows) == ["hello agent"]
            }
        )
    }

    @Test("send failure marks the pending row failed; retry delivers it")
    func sendFailureThenRetry() async {
        let source = FailingChatEventSource(failuresRemaining: 1)
        let store = Self.makeStore(source: source)

        await store.send(text: "flaky prompt")
        let failed = Self.pendingItems(store.rows)
        #expect(failed.count == 1)
        guard let item = failed.first, case .failed = item.delivery else {
            Issue.record("expected a failed pending row, got \(failed)")
            return
        }
        #expect(store.lastErrorDescription != nil)

        await store.retry(pendingID: item.id)
        #expect(Self.pendingItems(store.rows).first?.delivery == .delivered)
        #expect(store.lastErrorDescription == nil)
    }

    @Test("retry while the agent is working re-queues instead of delivering")
    func retryWhileWorkingRequeues() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        // First send fails (agent idle) → a failed pending row.
        await source.setSendFailure(true)
        await store.send(text: "flaky")
        #expect(await TestPoller.waitUntil {
            if case .failed = Self.pendingItems(store.rows).first?.delivery { return true }
            return false
        })
        await source.setSendFailure(false)

        // The agent goes back to working; retrying now must QUEUE, not paste-
        // submit into the busy agent (the stranded-Enter bug retry shared with
        // send before the fix).
        let working = ChatAgentState.working(since: Self.baseTime)
        await source.emit(.stateChanged(working))
        #expect(await TestPoller.waitUntil { store.agentState == working })

        guard let id = Self.pendingItems(store.rows).first?.id else {
            Issue.record("expected a pending row to retry")
            return
        }
        await store.retry(pendingID: id)
        #expect(Self.pendingItems(store.rows).first?.delivery == .queued)

        // And it flushes cleanly once the agent next goes idle.
        await source.emit(.stateChanged(.idle))
        #expect(await TestPoller.waitUntil {
            Self.pendingItems(store.rows).first?.delivery == .delivered
        })
    }

    @Test("a newer send's echo evicts an older delivered pending that never reconciled")
    func staleDeliveredPendingEvictedByLaterEcho() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        // Two sends, both delivered (SilentSend never echoes on its own).
        await store.send(text: "alpha")
        await store.send(text: "beta")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 2 })

        // Only beta's echo arrives. It reconciles beta; alpha — an OLDER
        // delivered row whose echo never matched — is swept as stale rather
        // than lingering as a permanent duplicate.
        await source.emit(.appended([Self.prose(seq: 0, role: .user, text: "beta")]))
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).isEmpty })
    }

    @Test("a delivered pending survives when no newer send has reconciled")
    func deliveredPendingSurvivesWithoutLaterEcho() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        await store.send(text: "alpha")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })

        // An unrelated user message that matches nothing must NOT evict the
        // lone delivered pending (no later send reconciled, so it is not stale).
        await source.emit(.appended([Self.prose(seq: 0, role: .user, text: "unrelated")]))
        #expect(await TestPoller.waitUntil {
            Self.userProseTexts(store.rows).contains("unrelated")
        })
        #expect(Self.pendingItems(store.rows).map(\.text) == ["alpha"])
    }

    @Test("discard removes a failed pending row")
    func discardRemovesFailedPending() async {
        let source = FailingChatEventSource(failuresRemaining: .max)
        let store = Self.makeStore(source: source)

        await store.send(text: "doomed prompt")
        let failed = Self.pendingItems(store.rows)
        guard let item = failed.first, case .failed = item.delivery else {
            Issue.record("expected a failed pending row, got \(failed)")
            return
        }

        store.discard(pendingID: item.id)
        #expect(Self.pendingItems(store.rows).isEmpty)
    }

    // MARK: - Pagination

    @Test("loadOlder prepends older pages and updates hasMoreHistory")
    func loadOlderPrepends() async {
        let source = FixtureChatEventSource(backlog: Self.backlog(count: 25))
        let store = Self.makeStore(source: source, pageSize: 10)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })
        #expect(Self.snapshots(store.rows).first?.message.seq == 15)
        #expect(store.hasMoreHistory == true)

        await store.loadOlder()
        var snaps = Self.snapshots(store.rows)
        #expect(snaps.count == 20)
        #expect(snaps.map(\.message.seq) == Array(5..<25))
        #expect(store.hasMoreHistory == true)

        await store.loadOlder()
        snaps = Self.snapshots(store.rows)
        #expect(snaps.count == 25)
        #expect(snaps.map(\.message.seq) == Array(0..<25))
        #expect(store.hasMoreHistory == false)
    }

    // MARK: - Unread separator

    @Test("lastReadSeq places the unread separator before the first unseen message")
    func unreadSeparatorPlacement() async {
        let source = FixtureChatEventSource(backlog: Self.backlog(count: 6))
        let store = Self.makeStore(source: source, lastReadSeq: 2)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }

        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })
        guard let separatorIndex = store.rows.firstIndex(of: .unreadSeparator) else {
            Issue.record("missing unread separator in \(store.rows)")
            return
        }
        guard case .message(let next) = store.rows[separatorIndex + 1] else {
            Issue.record("expected a message right after the separator")
            return
        }
        #expect(next.message.seq == 3)
    }

    // MARK: - Lifecycle

    @Test("cancelling run() disconnects the store")
    func cancellationDisconnects() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }

        #expect(await TestPoller.waitUntil { store.isConnected })
        runTask.cancel()
        await runTask.value
        #expect(store.isConnected == false)
    }

    @Test("idle descriptor snapshot flushes a queued send")
    func idleDescriptorSnapshotFlushesQueuedSend() async {
        let source = SilentSendEventSource()
        let workingDescriptor = ChatSessionDescriptor(
            id: "session-1",
            agentKind: .claude,
            title: "Test",
            state: .working(since: Self.baseTime),
            version: 1
        )
        let store = ChatConversationStore(
            descriptor: workingDescriptor,
            source: source,
            now: { Self.baseTime }
        )

        await store.send(text: "queued from snapshot")
        #expect(Self.pendingItems(store.rows).first?.delivery == .queued)

        store.applyDescriptorSnapshot(
            ChatSessionDescriptor(
                id: "session-1",
                agentKind: .claude,
                title: "Test",
                state: .idle,
                version: 2
            )
        )

        #expect(await TestPoller.waitUntil {
            Self.pendingItems(store.rows).first?.delivery == .delivered
        })
    }

    @Test("a live replay overlapping a long history page does not duplicate rows")
    func replayOverlappingHistoryDeduplicates() async {
        // 100-message page plus a buffered replay of the same 100 (one
        // tailer drain emitted mid-fetch); the window must stay at 100.
        let backlog = Self.backlog(count: 100)
        let source = FixtureChatEventSource(backlog: backlog)
        let store = Self.makeStore(source: source, pageSize: 100)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })

        await source.emit(.appended(backlog))
        _ = await TestPoller.waitUntil { Self.snapshots(store.rows).count > 100 }
        #expect(Self.snapshots(store.rows).count == 100)
    }

    @Test("a paste-placeholder echo reconciles a multi-line pending send")
    func pastePlaceholderEchoReconciles() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        await store.send(text: "line one\nline two\nline three")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })

        let echo = ChatMessage(
            id: "echo-paste",
            seq: 0,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "[Pasted text #1 +3 lines]"))
        )
        await source.emit(.appended([echo]))
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).isEmpty })
    }

    @Test("a failed send's retry row survives other sends' echoes")
    func failedPendingSurvivesForeignEchoes() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        // The OLDEST pending is the failed one (load-bearing for the
        // guard: oldest-first matching would otherwise consume it).
        await source.setSendFailure(true)
        await store.send(text: "first\nfailed send")
        #expect(await TestPoller.waitUntil {
            Self.pendingItems(store.rows).contains { if case .failed = $0.delivery { return true }; return false }
        })
        await source.setSendFailure(false)
        await store.send(text: "second\ndelivered send")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 2 })

        let echo = ChatMessage(
            id: "echo-ph",
            seq: 0,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "[Pasted text #1 +2 lines]"))
        )
        await source.emit(.appended([echo]))
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })
        // One non-failed pending was consumed; the failed row remains.
        let remaining = Self.pendingItems(store.rows)
        #expect(remaining.count == 1)
        if case .failed = remaining[0].delivery {} else {
            Issue.record("expected the failed retry row to survive")
        }
    }

    @Test("a slash-command echo cannot consume an attachment-only pending")
    func slashCommandEchoDoesNotEatAttachmentPending() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        let attachment = ChatOutboundAttachment(data: Data([0x89]), format: .png)
        await store.send(text: "", attachments: [attachment])
        await store.send(text: "/compact")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 2 })

        let slashEcho = ChatMessage(
            id: "echo-slash",
            seq: 0,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "/compact"))
        )
        await source.emit(.appended([slashEcho]))
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })
        // The exact-text match consumed "/compact"; the attachment-only
        // pending survives until its clipboard-path echo arrives.
        #expect(Self.pendingItems(store.rows).first?.text.isEmpty == true)

        let pathEcho = ChatMessage(
            id: "echo-clip",
            seq: 1,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "/tmp/clipboard-2026-06-12-110000-abc123.png"))
        )
        await source.emit(.appended([pathEcho]))
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).isEmpty })
    }

    @Test("a successful resync after reset clears a stale error banner")
    func resyncAfterResetClearsStaleError() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        // A failed send leaves an error banner.
        await source.setSendFailure(true)
        await store.send(text: "will fail")
        #expect(await TestPoller.waitUntil { store.lastErrorDescription != nil })

        // Reset empties the window; apply(.reset) kicks resyncTail, which
        // succeeds via the empty-window branch and must clear the banner.
        await source.emit(.reset)
        #expect(await TestPoller.waitUntil { store.lastErrorDescription == nil })
    }

    @Test("a reset event clears the window and re-anchors from history")
    func resetEventReanchors() async {
        let backlog = Self.backlog(count: 5)
        let source = FixtureChatEventSource(backlog: backlog)
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { Self.snapshots(store.rows).count == 5 })

        // Rewrite: fixture backlog replaced, reset pushed, new content lands.
        await source.emit(.reset)
        #expect(await TestPoller.waitUntil { Self.snapshots(store.rows).count <= 1 })
        let rewritten = ChatMessage(
            id: "rw-0", seq: 0, role: .user, timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "fresh transcript"))
        )
        await source.emit(.appended([rewritten]))
        #expect(await TestPoller.waitUntil {
            Self.userProseTexts(store.rows) == ["fresh transcript"]
        })
    }

    @Test("a path-prefixed echo reconciles a text-plus-image send")
    func pathPrefixedEchoReconciles() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        let attachment = ChatOutboundAttachment(data: Data([0x89]), format: .png)
        await store.send(text: "what is in this screenshot", attachments: [attachment])
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })

        let echo = ChatMessage(
            id: "echo-path",
            seq: 0,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "/tmp/clipboard-2026-06-12-110000-abc1.png what is in this screenshot"))
        )
        await source.emit(.appended([echo]))
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).isEmpty })
    }

    @Test("a seq regression in a live append re-anchors the window instead of corrupting order")
    func seqRegressionReanchors() async {
        let source = FixtureChatEventSource(backlog: Self.backlog(count: 6))
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })
        #expect(Self.snapshots(store.rows).count == 6)

        // Transcript truncated and rewritten: fresh ids, seqs restart at 0.
        let rewritten = [
            ChatMessage(id: "r0", seq: 0, role: .user, timestamp: Self.baseTime, kind: .prose(ChatProse(text: "rewritten"))),
            ChatMessage(id: "r1", seq: 1, role: .agent, timestamp: Self.baseTime, kind: .prose(ChatProse(text: "ok"))),
        ]
        await source.emit(.appended(rewritten))
        #expect(await TestPoller.waitUntil { Self.snapshots(store.rows).count == 2 })
        #expect(store.rows.compactMap { row -> Int? in
            if case .message(let snapshot) = row { return snapshot.message.seq }
            return nil
        } == [0, 1])
    }

    @Test("a send while the agent is working is queued, then flushed on idle")
    func sendWhileWorkingQueuesThenFlushes() async {
        // FixtureChatEventSource echoes a delivered send into the
        // transcript, so a flushed queue shows up as a real user message —
        // all observed through the synchronous store-state poller.
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        await source.emit(.stateChanged(.working(since: Self.baseTime)))
        #expect(await TestPoller.waitUntil { store.agentState == .working(since: Self.baseTime) })
        await store.send(text: "queued while busy")

        // Queued, not delivered: the prompt has not echoed into the transcript.
        #expect(await TestPoller.waitUntil {
            Self.pendingItems(store.rows).contains { $0.delivery == .queued }
        })
        #expect(!Self.userProseTexts(store.rows).contains("queued while busy"))

        // Idle → the queued send flushes and the fixture echoes it.
        await source.emit(.stateChanged(.idle))
        #expect(await TestPoller.waitUntil {
            Self.userProseTexts(store.rows).contains("queued while busy")
        })
        #expect(Self.pendingItems(store.rows).allSatisfy { $0.delivery != .queued })
    }

    @Test("multiple sends queued while working flush ONE per idle turn, in order")
    func queuedSendsFlushOnePerIdleTurn() async {
        // FixtureChatEventSource echoes each delivered send as a user
        // message, so the count of user prose = number actually flushed.
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        await source.emit(.stateChanged(.working(since: Self.baseTime)))
        #expect(await TestPoller.waitUntil { store.agentState == .working(since: Self.baseTime) })
        await store.send(text: "first")
        await store.send(text: "second")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).filter { $0.delivery == .queued }.count == 2 })

        // First idle window flushes exactly ONE (the older), not both.
        await source.emit(.stateChanged(.idle))
        #expect(await TestPoller.waitUntil { Self.userProseTexts(store.rows) == ["first"] })
        #expect(Self.pendingItems(store.rows).filter { $0.delivery == .queued }.count == 1)

        // A working->idle turn re-arms the flush for the second.
        await source.emit(.stateChanged(.working(since: Self.baseTime)))
        await source.emit(.stateChanged(.idle))
        #expect(await TestPoller.waitUntil { Self.userProseTexts(store.rows) == ["first", "second"] })
        #expect(Self.pendingItems(store.rows).allSatisfy { $0.delivery != .queued })
    }

    @Test("a send while the agent is idle delivers immediately")
    func sendWhileIdleDeliversNow() async {
        let source = FixtureChatEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        await store.send(text: "immediate message")
        #expect(await TestPoller.waitUntil {
            Self.userProseTexts(store.rows).contains("immediate message")
        })
    }

    @Test("a budget-truncated transcript echo still reconciles the pending row")
    func truncatedEchoReconciles() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        let longText = String(repeating: "prompt body ", count: 30)
        await store.send(text: longText)
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })

        let truncated = String(longText.prefix(100)) + "…"
        let echo = ChatMessage(
            id: "echo-1",
            seq: 0,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: truncated))
        )
        await source.emit(.appended([echo]))

        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).isEmpty })
        #expect(Self.userProseTexts(store.rows) == [truncated])
    }

    @Test("a transcript echo with a short stale prompt prefix still reconciles the pending row")
    func stalePromptPrefixEchoReconciles() async {
        let source = SilentSendEventSource()
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.isConnected })

        await store.send(text: "not much u?")
        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).count == 1 })

        let prefixedEcho = ChatMessage(
            id: "echo-1",
            seq: 0,
            role: .user,
            timestamp: Self.baseTime,
            kind: .prose(ChatProse(text: "ynot much u?"))
        )
        await source.emit(.appended([prefixedEcho]))

        #expect(await TestPoller.waitUntil { Self.pendingItems(store.rows).isEmpty })
        #expect(Self.userProseTexts(store.rows) == ["ynot much u?"])
    }

    @Test("an empty page at the Mac's cache head ends paging and flags head truncation")
    func emptyPageAtCacheHeadStopsPaging() async {
        let newest = (100..<104).map { Self.prose(seq: $0) }
        let source = TruncatedHeadEventSource(newest: newest)
        let store = Self.makeStore(source: source)
        let runTask = Task { await store.run() }
        defer { runTask.cancel() }
        #expect(await TestPoller.waitUntil { store.hasLoadedInitialHistory })
        #expect(store.hasMoreHistory)
        #expect(store.historyTruncatedAtHead == false)

        await store.loadOlder()

        #expect(store.hasMoreHistory == false)
        #expect(store.historyTruncatedAtHead)
        #expect(Self.snapshots(store.rows).count == 4)
    }
}
