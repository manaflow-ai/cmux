import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationListStateRulesTests {
    @Test func unpinningClearsTheOrderAndDeletingUnpinsAndClearsUnread() {
        let pinned = ConversationListState().applying(.init(pinned: true, pinOrder: 2))
        #expect(pinned.pinned && pinned.pinOrder == 2)
        #expect(pinned.applying(.init(pinned: false)).pinOrder == nil)

        let busy = ConversationListState(pinned: true, pinOrder: 0, muted: true, markedUnread: true)
        let deleted = busy.applying(.init(deleted: true))
        #expect(deleted == ConversationListState(pinned: false, pinOrder: nil, muted: true, markedUnread: false, deleted: true))
    }

    @Test func pinOrderIsIgnoredForAnUnpinnedConversation() {
        #expect(ConversationListState().applying(.init(pinOrder: 3)).pinOrder == nil)
    }

    @Test func arrangementPutsPinsFirstInPinOrderAndHidesDeleted() {
        typealias Item = ConversationListArrangement.Item<String>
        let items = [
            Item(id: "old", state: .init(), lastActivity: Date(timeIntervalSince1970: 10)),
            Item(id: "new", state: .init(), lastActivity: Date(timeIntervalSince1970: 30)),
            Item(id: "pinB", state: .init(pinned: true, pinOrder: 1), lastActivity: Date(timeIntervalSince1970: 50)),
            Item(id: "pinA", state: .init(pinned: true, pinOrder: 0), lastActivity: Date(timeIntervalSince1970: 1)),
            Item(id: "gone", state: .init(deleted: true), lastActivity: Date(timeIntervalSince1970: 99)),
        ]
        let arranged = ConversationListArrangement.arrange(items)
        #expect(arranged.pinned == ["pinA", "pinB"])
        #expect(arranged.others == ["new", "old"])
    }

    @Test func pinLimitIsNine() {
        #expect(ConversationListArrangement.canPin(pinnedCount: 8))
        #expect(!ConversationListArrangement.canPin(pinnedCount: 9))
    }

    @Test func reorderingReturnsOnlyChangedOrders() {
        let current = ["a": 0, "b": 1, "c": 2]
        // Drag "c" to the front.
        #expect(ConversationListArrangement.pinOrders(pinned: ["a", "b", "c"], current: current, moving: "c", to: 0) == ["c": 0, "a": 1, "b": 2])
        // Dropping in place changes nothing.
        #expect(ConversationListArrangement.pinOrders(pinned: ["a", "b", "c"], current: current, moving: "b", to: 1).isEmpty)
        // Pinning "d" by dragging it between "a" and "b".
        #expect(ConversationListArrangement.pinOrders(pinned: ["a", "b", "c"], current: current, moving: "d", to: 1) == ["d": 1, "b": 2, "c": 3])
    }

    @Test func wireDecodingReadsListStateAndDefaultsMissingFields() {
        let full = WireDecoding.conversation([
            "id": "g", "title": "cmux", "kind": "group", "participants": [],
            "pinned": true, "pinOrder": 4, "muted": true, "markedUnread": true, "deleted": false,
        ])
        #expect(full?.listState == ConversationListState(pinned: true, pinOrder: 4, muted: true, markedUnread: true, deleted: false))
        let legacy = WireDecoding.conversation(["id": "g", "title": "cmux", "kind": "group", "participants": []])
        #expect(legacy?.listState == ConversationListState())
        let strayOrder = WireDecoding.conversation(["id": "g", "pinned": false, "pinOrder": 2])
        #expect(strayOrder?.listState.pinOrder == nil)
    }
}

@MainActor
@Suite struct ConversationStoreListStateTests {
    @Test func listActionAppliesAtOnceThenTakesTheServersState() async throws {
        let backend = ListStateBackend()
        backend.hold = true
        let store = ConversationStore(backend: backend)
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))

        store.updateListState(.init(pinned: true))
        #expect(store.listState.pinned)
        #expect(changes.last == .listState)
        backend.server.pinOrder = 7
        backend.release()
        try await waitUntil { store.listState.pinOrder == 7 }
        #expect(backend.received == [.init(pinned: true)])
    }

    @Test func rejectedListActionRollsBack() async throws {
        let backend = ListStateBackend()
        backend.fail = true
        let store = ConversationStore(backend: backend)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        var rejection: ConversationBackendError?
        store.updateListState(.init(muted: true)) { rejection = $0 }
        #expect(store.listState.muted)
        try await waitUntil { !store.listState.muted }
        #expect(rejection?.code == -32004)
        #expect(backend.received.count == 1)
    }

    @Test func aStaleReplyDoesNotOverwriteANewerPush() async throws {
        let backend = ListStateBackend()
        backend.hold = true
        let store = ConversationStore(backend: backend)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        store.updateListState(.init(markedUnread: true))
        // Another device deletes the conversation before the reply lands.
        var pushed = backend.info
        pushed.listState = ConversationListState(deleted: true)
        store.apply(.conversationChanged(pushed))
        backend.fail = true
        backend.release()
        try await waitUntil { backend.replied }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.listState == ConversationListState(deleted: true))
    }

    @Test func noOpActionIsNotSent() async throws {
        let backend = ListStateBackend()
        let store = ConversationStore(backend: backend)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        store.updateListState(.init(pinned: false, muted: false))
        try await Task.sleep(for: .milliseconds(20))
        #expect(backend.received.isEmpty)
    }

    @Test func backendsWithoutAListRejectListActions() async {
        let backend = ScriptedBackend(total: 1)
        await #expect(throws: ConversationBackendError.self) {
            _ = try await backend.updateListState(.init(pinned: true))
        }
    }
}

/// Applies list actions like the server, optionally holding or failing them.
final class ListStateBackend: ConversationBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
    ])
    private let lock = NSLock()
    private var _server = ConversationListState()
    private var _hold = false
    private var _fail = false
    private var _received: [ConversationListStateChange] = []
    private var _replied = false
    private var _waiters: [CheckedContinuation<Void, Never>] = []

    var server: ConversationListState { get { lock.withLock { _server } } set { lock.withLock { _server = newValue } } }
    var hold: Bool { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }
    var fail: Bool { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
    var received: [ConversationListStateChange] { lock.withLock { _received } }
    var replied: Bool { lock.withLock { _replied } }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _hold = false
            defer { _waiters = [] }
            return _waiters
        }
        waiters.forEach { $0.resume() }
    }

    func updateListState(_ change: ConversationListStateChange) async throws -> ConversationInfo {
        let held = lock.withLock { () -> Bool in
            _received.append(change)
            return _hold
        }
        if held {
            await withCheckedContinuation { waiter in
                let resumeNow = lock.withLock { () -> Bool in
                    guard _hold else { return true }
                    _waiters.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        defer { lock.withLock { _replied = true } }
        if fail { throw ConversationBackendError(code: -32004, message: "pin limit") }
        var result = info
        let state = lock.withLock { () -> ConversationListState in
            let pinOrder = _server.pinOrder
            _server = _server.applying(change)
            if _server.pinned, let pinOrder { _server.pinOrder = pinOrder }
            return _server
        }
        result.listState = state
        return result
    }

    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { _ in } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: [], hasMore: false)
    }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func edit(messageID: String, text: String) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }
    func close() {}
}
