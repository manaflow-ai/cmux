import Foundation
import Testing
@testable import CmuxConversationCore

/// Unread counting, marking read while viewing, and the catch-up target.
/// ScriptedBackend: messages whose seq is divisible by 3 are mine.
@MainActor
@Suite struct ConversationReadStateTests {
    private func loadedStore(total: Int = 100, pageSize: Int = 30) async throws -> (ConversationStore, ScriptedBackend) {
        let backend = ScriptedBackend(total: total)
        let store = ConversationStore(backend: backend, pageSize: pageSize)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        return (store, backend)
    }

    @Test func unreadAboveTheWindowComesFromTheServiceAndGrowsWithArrivals() async throws {
        let (store, backend) = try await loadedStore()
        var changes: [ConversationStoreChange] = []
        store.onChange = { changes.append($0) }
        store.apply(.readState(ConversationReadState(lastReadSeq: 50, unreadCount: 30, headSeq: 100)))
        #expect(store.unreadCount == 30)
        #expect(changes.contains(.readState))
        store.apply(.message(backend.makeMessage(seq: 101, sender: "lc"), eventSeq: 1))
        #expect(store.unreadCount == 31)
        store.apply(.message(backend.makeMessage(seq: 102, sender: "me"), eventSeq: 2))
        #expect(store.unreadCount == 31)
        #expect(backend.markedRead.isEmpty)
    }

    @Test func unreadInsideTheWindowIsCountedExactly() async throws {
        let (store, _) = try await loadedStore()
        // 91...100 from others: 91 92 94 95 97 98 100.
        store.apply(.readState(ConversationReadState(lastReadSeq: 90, unreadCount: 99, headSeq: 100)))
        #expect(store.unreadCount == 7)
    }

    @Test func viewingReadsEverythingAndCapturesTheCatchUpTarget() async throws {
        let (store, backend) = try await loadedStore()
        store.apply(.readState(ConversationReadState(lastReadSeq: 50, unreadCount: 34, headSeq: 100)))
        store.setViewing(true)
        #expect(store.unreadCount == 0)
        #expect(store.lastReadSeq == 100)
        #expect(store.catchUpMarker == 50)
        #expect(store.catchUpCount == 34)
        try await waitUntil { backend.markedRead == [100] }
        // Arrivals while viewing are read at once (the receipt goes out).
        store.apply(.message(backend.makeMessage(seq: 101, sender: "lc"), eventSeq: 1))
        #expect(store.unreadCount == 0)
        try await waitUntil { backend.markedRead == [100, 101] }
        // The catch-up target survives reading and is still above the window.
        #expect(store.catchUpMarker == 50)
        #expect(store.catchUpTarget == nil)
        let rowID = await store.loadCatchUpTarget()
        // 51 is mine, so the first unread from others is 52.
        #expect(rowID == "s:m52")
        #expect(store.messages.first?.seq ?? .max <= 51)
        #expect(store.catchUpTarget?.seq == 52)
        store.dismissCatchUp()
        #expect(store.catchUpMarker == nil)
    }

    @Test func nothingUnreadMeansNoCatchUp() async throws {
        let (store, _) = try await loadedStore()
        store.apply(.readState(ConversationReadState(lastReadSeq: 100, unreadCount: 0, headSeq: 100)))
        store.setViewing(true)
        #expect(store.catchUpMarker == nil)
    }

    @Test func leavingEndsCatchUpAndLaterArrivalsCountAgain() async throws {
        let (store, backend) = try await loadedStore()
        store.apply(.readState(ConversationReadState(lastReadSeq: 80, unreadCount: 14, headSeq: 100)))
        store.setViewing(true)
        #expect(store.catchUpMarker == 80)
        store.setViewing(false)
        #expect(store.catchUpMarker == nil)
        store.apply(.message(backend.makeMessage(seq: 101, sender: "lc"), eventSeq: 1))
        store.apply(.message(backend.makeMessage(seq: 102, sender: "aw"), eventSeq: 2))
        #expect(store.unreadCount == 2)
        // Coming back: the two new ones are the catch-up backlog.
        store.setViewing(true)
        #expect(store.catchUpMarker == 100)
        #expect(store.catchUpCount == 2)
        #expect(store.unreadCount == 0)
    }

    @Test func anotherDeviceReadingClearsUnreadButAStaleConfirmationNeverRegresses() async throws {
        let (store, _) = try await loadedStore()
        store.apply(.readState(ConversationReadState(lastReadSeq: 50, unreadCount: 34, headSeq: 100)))
        store.apply(.readState(ConversationReadState(lastReadSeq: 100, unreadCount: 0, headSeq: 100)))
        #expect(store.unreadCount == 0)
        store.apply(.readState(ConversationReadState(lastReadSeq: 90, unreadCount: 7, headSeq: 100)))
        #expect(store.unreadCount == 7)
        store.markNewestRead()
        #expect(store.unreadCount == 0)
        // A confirmation of an older read (in flight before mine) is ignored.
        store.apply(.readState(ConversationReadState(lastReadSeq: 95, unreadCount: 3, headSeq: 100)))
        #expect(store.lastReadSeq == 100)
        #expect(store.unreadCount == 0)
    }

    @Test func sendingReadsTheConversation() async throws {
        let (store, backend) = try await loadedStore()
        store.apply(.readState(ConversationReadState(lastReadSeq: 90, unreadCount: 7, headSeq: 100)))
        store.send(text: "caught up")
        try await waitUntil { backend.sendCount == 1 }
        try await waitUntil { store.unreadCount == 0 }
        #expect(store.lastReadSeq == 101)
    }

    @Test func unreadBadgeTotalsOtherConversations() async throws {
        let (a, backendA) = try await loadedStore()
        let (b, _) = try await loadedStore()
        let badge = ConversationUnreadBadge(stores: [a, b])
        var updates = 0
        badge.onChange = { updates += 1 }
        a.apply(.readState(ConversationReadState(lastReadSeq: 90, unreadCount: 7, headSeq: 100)))
        b.apply(.readState(ConversationReadState(lastReadSeq: 50, unreadCount: 30, headSeq: 100)))
        #expect(badge.total == 37)
        #expect(badge.total(excluding: b) == 7)
        a.apply(.message(backendA.makeMessage(seq: 101, sender: "lc"), eventSeq: 1))
        #expect(badge.total(excluding: b) == 8)
        #expect(updates >= 3)
    }
}
