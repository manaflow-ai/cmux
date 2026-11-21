import AppKit
import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxConversationMacUI

/// A conversation left open at the bottom (a Chief chat for days) keeps its
/// loaded window bounded as messages arrive, without the reader scrolling.
@MainActor
@Suite(.serialized) struct MacConversationWindowBoundTests {
    @Test func liveArrivalsWhileRestingAtTheBottomBoundTheWindow() async throws {
        let lab = try await Lab()
        let store = lab.controller.store
        let start = (store.messages.last?.seq ?? 0) + 1
        let arrivals = ConversationStore.windowTrimThreshold + 10
        for seq in start..<(start + arrivals) {
            let message = ConversationMessage(id: "live\(seq)", seq: seq, clientMessageID: nil, senderID: "lc",
                                              sentAt: Date(), text: "update \(seq)")
            store.apply(.message(message, eventSeq: seq))
        }
        // Before the fix nothing trims until the reader scrolls: every message stays.
        try await waitUntil(timeout: .seconds(10)) { store.messages.count <= ConversationStore.windowKeepCount }
        #expect(store.messages.count <= ConversationStore.windowKeepCount)
        #expect(store.messages.last?.seq == start + arrivals - 1)
        store.stop()
    }
}
