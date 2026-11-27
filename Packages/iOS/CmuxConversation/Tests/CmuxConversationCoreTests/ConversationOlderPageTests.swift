import Foundation
import Testing
@testable import CmuxConversationCore

/// An older page joins the loaded window in front, without walking it: the
/// positions of the messages already loaded move as one, and only the
/// page's messages are sorted and indexed.
@Suite struct ConversationMessagePositionsTests {
    @Test func positionsReadBackWhatWasWritten() {
        var positions: ConversationMessagePositions = [:]
        positions["a"] = 0
        positions["b"] = 1
        #expect(positions["a"] == 0)
        #expect(positions["b"] == 1)
        #expect(positions["c"] == nil)
        positions["a"] = nil
        #expect(positions["a"] == nil)
    }

    @Test func aPageInFrontMovesEveryLoadedPositionByItsSize() {
        var positions: ConversationMessagePositions = [:]
        positions["m10"] = 0
        positions["m11"] = 1
        positions.shift(by: 2)
        positions["m8"] = 0
        positions["m9"] = 1
        #expect(positions["m8"] == 0)
        #expect(positions["m9"] == 1)
        #expect(positions["m10"] == 2)
        #expect(positions["m11"] == 3)
        // A position written after the shift reads back as written.
        positions["m11"] = 7
        #expect(positions["m11"] == 7)
    }

    @Test func removingAllForgetsTheShift() {
        var positions: ConversationMessagePositions = [:]
        positions["a"] = 0
        positions.shift(by: 5)
        positions.removeAll(keepingCapacity: true)
        #expect(positions["a"] == nil)
        positions["b"] = 3
        #expect(positions["b"] == 3)
    }
}

@MainActor
@Suite struct ConversationOlderPageTests {
    /// Every message's indexed position is where it sits.
    private func expectIndexed(_ store: ConversationStore) {
        for (index, message) in store.messages.enumerated() {
            #expect(store.messageIndex(id: message.id) == index)
        }
    }

    @Test func olderPagesKeepEveryPositionIndexed() async throws {
        let backend = ScriptedBackend(total: 200)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        for expected in [60, 90, 120] {
            store.loadOlder()
            try await waitUntil { store.messages.count == expected }
            #expect(store.messages.compactMap(\.seq) == Array((201 - expected)...200))
            expectIndexed(store)
        }
    }

    @Test func aFailedSendKeepsItsPlaceWhenAnOlderPageLands() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "client-f" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        backend.failNextSend = true
        let rowID = try #require(store.send(text: "nope"))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        var later = backend.makeMessage(seq: 101, sender: "lc")
        later.sentAt = Date().addingTimeInterval(5)
        store.apply(.message(later, eventSeq: 1))
        store.loadOlder()
        try await waitUntil { store.messages.count == 62 }
        #expect(store.messages.first?.seq == 41)
        #expect(store.messages.last?.id == "m101")
        #expect(store.messages[store.messages.count - 2].rowID == rowID)
        expectIndexed(store)
    }

    @Test func repliesBelowAPageToItsMessagesAreFound() async throws {
        let backend = ScriptedBackend(total: 100)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        // Replies to messages not loaded yet (m50 and m45), and one to a loaded message.
        var reply = backend.makeMessage(seq: 101, sender: "lc")
        reply.replyToID = "m50"
        store.apply(.message(reply, eventSeq: 1))
        var loaded = backend.makeMessage(seq: 102, sender: "lc")
        loaded.replyToID = "m90"
        store.apply(.message(loaded, eventSeq: 2))
        var other = backend.makeMessage(seq: 103, sender: "me")
        other.replyToID = "m45"
        store.apply(.message(other, eventSeq: 3))
        store.loadOlder()
        try await waitUntil { store.messages.count == 63 }
        let page = Set(store.messages[..<30].map(\.id))
        let found = store.messageIndices(from: 30, replyingTo: page)
        #expect(found.map { store.messages[$0].id } == ["m101", "m103"])
        #expect(store.messageIndices(from: 61, replyingTo: page).map { store.messages[$0].id } == ["m103"])
        #expect(store.messageIndices(from: 30, replyingTo: []).isEmpty)
    }
}
