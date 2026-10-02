import Foundation
import Testing
@testable import CmuxConversationCore

@MainActor
@Suite struct ConversationStoreTests {
    @Test func newestPageThenOlderPagePrependsContiguousHistory() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.messages.compactMap(\.seq) == Array(71...100))
        #expect(store.older == .idle)

        store.loadOlder()
        #expect(store.older == .loading)
        try await waitUntil { store.messages.count == 60 }
        #expect(store.messages.compactMap(\.seq) == Array(41...100))
        #expect(changes.contains(.prepended))
    }

    @Test func olderFetchFailureRetriesThenSucceeds() async throws {
        let backend = ScriptedBackend(total: 100)
        backend.failNextHistory = 2
        let store = ConversationStore(backend: backend, pageSize: 30, clock: ImmediateClock())
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextHistory = 2
        store.loadOlder()
        try await waitUntil { store.messages.count == 60 }
        #expect(store.older == .idle)
    }

    @Test func historyExhaustsAtTheFirstMessage() async throws {
        let backend = ScriptedBackend(total: 45)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.loadOlder()
        try await waitUntil { store.older == .exhausted }
        #expect(store.messages.compactMap(\.seq) == Array(1...45))
    }

    @Test func duplicateAndStaleEventsAreIgnored() async throws {
        let backend = ScriptedBackend(total: 10)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let live = backend.makeMessage(seq: 11, sender: "lc")
        store.apply(.message(live, eventSeq: 500))
        store.apply(.message(live, eventSeq: 500))
        var stale = live
        stale.text = "stale"
        store.apply(.message(stale, eventSeq: 499))
        #expect(store.messages.count == 11)
        #expect(store.messages.last?.text == live.text)
    }

    @Test func optimisticSendKeepsRowIdentityThroughAckAndDeliveryNeverRegresses() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.holdSend = true
        let rowID = try #require(store.send(text: "hello"))
        #expect(store.messages.last?.rowID == rowID)
        #expect(store.messages.last?.delivery == .sending)

        // The live echo (delivered) races ahead of the ack (sent).
        var echo = backend.makeMessage(seq: 6, sender: "me")
        echo.clientMessageID = "client-1"
        echo.text = "hello"
        echo.delivery = .delivered
        store.apply(.message(echo, eventSeq: 900))
        backend.releaseSend()
        try await waitUntil { backend.sendCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.messages.filter { $0.rowID == rowID }.count == 1)
        #expect(store.messages.count == 6)
        #expect(store.messages.last?.delivery == .delivered)
    }

    @Test func failedSendStaysVisibleAndRetryReusesClientID() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-2" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "will fail"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        store.retry(rowID: rowID)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(backend.sentClientIDs == ["client-2", "client-2"])
    }

    @Test func laggedReconnectRebasesOnNewestAndKeepsPendingSends() async throws {
        let backend = ScriptedBackend(total: 50)
        let store = ConversationStore(backend: backend, pageSize: 20, makeClientMessageID: { "client-3" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.holdSend = true
        store.send(text: "in flight")
        backend.total = 80
        store.apply(.connected(info: backend.info, meID: "me", lagged: true))
        try await waitUntil { store.messages.first?.seq == 61 }
        #expect(store.messages.compactMap(\.seq) == Array(61...80))
        #expect(store.messages.last?.clientMessageID == "client-3")
        backend.releaseSend()
    }

    @Test func typingClearsWhenThatParticipantsMessageArrives() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.apply(.typing(participantID: "lc", isTyping: true))
        store.apply(.typing(participantID: "aw", isTyping: true))
        #expect(store.typingParticipantIDs == ["lc", "aw"])
        store.apply(.message(backend.makeMessage(seq: 6, sender: "lc"), eventSeq: 10))
        #expect(store.typingParticipantIDs == ["aw"])
    }
}

// MARK: - Test doubles

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met before timeout")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await Task.yield()
    }
}

final class ScriptedBackend: ConversationBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
        ConversationParticipant(id: "aw", name: "Austin Wang", initials: "AW", colorHex: "#8E8E93", isMe: false),
    ])
    private let lock = NSLock()
    private var _total: Int
    private var _failNextHistory = 0
    private var _failNextSend = false
    private var _holdSend = false
    private var _sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var _sentClientIDs: [String] = []
    private var _sendCount = 0

    init(total: Int) { _total = total }

    var total: Int { get { lock.withLock { _total } } set { lock.withLock { _total = newValue } } }
    var failNextHistory: Int { get { lock.withLock { _failNextHistory } } set { lock.withLock { _failNextHistory = newValue } } }
    var failNextSend: Bool { get { lock.withLock { _failNextSend } } set { lock.withLock { _failNextSend = newValue } } }
    var holdSend: Bool { get { lock.withLock { _holdSend } } set { lock.withLock { _holdSend = newValue } } }
    var sentClientIDs: [String] { lock.withLock { _sentClientIDs } }
    var sendCount: Int { lock.withLock { _sendCount } }

    func releaseSend() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdSend = false
            defer { _sendWaiters = [] }
            return _sendWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func makeMessage(seq: Int, sender: String) -> ConversationMessage {
        ConversationMessage(
            id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: sender,
            sentAt: Date(timeIntervalSince1970: TimeInterval(seq * 60)), text: "message \(seq)"
        )
    }

    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { _ in } }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        let shouldFail = lock.withLock { () -> Bool in
            guard _failNextHistory > 0 else { return false }
            _failNextHistory -= 1
            return true
        }
        if shouldFail { throw ConversationBackendError(code: -32001, message: "upstream timeout") }
        let upper = (beforeSeq ?? (total + 1)) - 1
        let lower = max(1, upper - limit + 1)
        guard upper >= 1 else { return ConversationHistoryPage(messages: [], hasMore: false) }
        return ConversationHistoryPage(
            messages: (lower...upper).map { makeMessage(seq: $0, sender: $0 % 3 == 0 ? "me" : "lc") },
            hasMore: lower > 1
        )
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        let (hold, fail) = lock.withLock { () -> (Bool, Bool) in
            _sentClientIDs.append(draft.clientMessageID)
            let fail = _failNextSend
            _failNextSend = false
            return (_holdSend, fail)
        }
        if hold {
            await withCheckedContinuation { waiter in
                let resumeNow = lock.withLock { () -> Bool in
                    guard _holdSend else { return true }
                    _sendWaiters.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        defer { lock.withLock { _sendCount += 1 } }
        if fail { throw ConversationBackendError(code: -32002, message: "not delivered") }
        var message = makeMessage(seq: total + 1, sender: "me")
        message.clientMessageID = draft.clientMessageID
        message.text = draft.text
        message.delivery = .sent
        return message
    }

    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }

    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        var message = makeMessage(seq: Int(messageID.dropFirst()) ?? 0, sender: "me")
        message.text = text
        message.editedAt = Date()
        return message
    }

    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        ConversationAttachment(id: "up", kind: .image, width: 10, height: 10, url: nil)
    }
    func close() {}
}

@MainActor
@Suite struct ConversationStoreUpdateTests {
    @Test func editsAndTapbacksReplaceTheMessageInPlace() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var edited = backend.makeMessage(seq: 5, sender: "lc")
        edited.text = "edited"
        edited.editedAt = Date()
        edited.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        store.apply(.message(edited, eventSeq: 1))
        #expect(store.messages.count == 5)
        #expect(store.messages.last?.text == "edited")
        #expect(store.messages.last?.reactions.first?.reaction == .haha)
        var removed = edited
        removed.reactions = []
        store.apply(.message(removed, eventSeq: 2))
        #expect(store.messages.last?.reactions.isEmpty == true)
    }

    @Test func receiptsNeverRegress() {
        #expect(ConversationStore.maxDelivery(.read(nil), .delivered) == .read(nil))
        #expect(ConversationStore.maxDelivery(.delivered, .sent) == .delivered)
        #expect(ConversationStore.maxDelivery(.sending, .delivered) == .delivered)
        #expect(ConversationStore.maxDelivery(.failed("x"), .sent) == .sent)
    }

    @Test func olderPagesDoNotOverwriteNewerLiveState() async throws {
        let backend = ScriptedBackend(total: 60)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var live = backend.makeMessage(seq: 31, sender: "lc")
        live.text = "edited live"
        store.apply(.message(live, eventSeq: 1))
        store.loadOlder()
        try await waitUntil { store.messages.count == 60 }
        #expect(store.message(id: "m31")?.text == "edited live")
        #expect(store.messages.compactMap(\.seq) == Array(1...60))
    }

    @Test func singleOlderRequestInFlight() async throws {
        let backend = ScriptedBackend(total: 200)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        store.loadOlder()
        store.loadOlder()
        store.loadOlder()
        try await waitUntil { store.older == .idle }
        #expect(store.messages.count == 60)
    }
}

@MainActor
@Suite struct ConversationStoreWindowTests {
    @Test func updatesAboveTheLoadedWindowAreNotInserted() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var old = backend.makeMessage(seq: 12, sender: "lc")
        old.reactions = [ConversationReactionMark(participantID: "aw", reaction: .question)]
        store.apply(.message(old, eventSeq: 1))
        #expect(store.message(id: "m12") == nil)
        #expect(store.messages.compactMap(\.seq) == Array(71...100))
        store.loadOlder()
        try await waitUntil { store.messages.count == 60 }
        #expect(store.messages.compactMap(\.seq) == Array(41...100))
    }
}

@MainActor
@Suite struct ConversationStoreEditTests {
    @Test func editingMyRecentMessageAppliesAtOnceAndMarksEdited() async throws {
        let backend = ScriptedBackend(total: 6)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var mine = backend.makeMessage(seq: 7, sender: "me")
        mine.sentAt = Date()
        store.apply(.message(mine, eventSeq: 1))
        #expect(store.canEdit(mine))
        store.edit(messageID: "m7", text: "fixed typo")
        #expect(store.message(id: "m7")?.text == "fixed typo")
        #expect(store.message(id: "m7")?.editedAt != nil)
        let old = backend.makeMessage(seq: 3, sender: "me")
        #expect(!store.canEdit(old))
    }
}

extension ConversationStoreWindowTests {
    @Test func updatesDuringTheInitialLoadDoNotOpenAGap() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        // An old message's tapback and a brand-new message race the first page.
        var old = backend.makeMessage(seq: 12, sender: "lc")
        old.reactions = [ConversationReactionMark(participantID: "aw", reaction: .haha)]
        store.apply(.message(old, eventSeq: 1))
        store.apply(.message(backend.makeMessage(seq: 101, sender: "aw"), eventSeq: 2))
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        #expect(store.messages.compactMap(\.seq) == Array(71...101))
    }
}

extension ConversationStoreWindowTests {
    @Test func aFailedSendKeepsItsPlaceWhenLaterMessagesArrive() async throws {
        let backend = ScriptedBackend(total: 3)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-f" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "nope"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        var later = backend.makeMessage(seq: 4, sender: "lc")
        later.sentAt = Date().addingTimeInterval(5)
        store.apply(.message(later, eventSeq: 1))
        #expect(store.messages.last?.id == "m4")
        #expect(store.messages[store.messages.count - 2].rowID == rowID)
    }
}
