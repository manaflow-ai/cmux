@testable import CmuxNextHome
import Foundation
import Testing

struct TranscriptWindowTests {
    @Test func pendingSettlesInPlaceWithTheSameRowIdentity() {
        let context = HomeFixture.context()
        var window = HomeFixture.window(1...50)
        var layout = TranscriptLayout()
        layout.rebuild(window, context: context)
        let pending = HomeFixture.pending("cm_1", at: 10_000)
        layout.apply(window.addPending(pending), window: window, context: context)
        let pendingKeys = layout.rows.filter { $0.messageKey == "cm_1" }.map(\.key)
        let pendingRow = layout.rows.first { $0.key == "cm_1#0" }
        #expect(pendingKeys.contains("cm_1#0"))
        #expect(layout.rows.contains { if case .label("Sending", _, _, _) = $0.kind { true } else { false } })

        var confirmed = pending
        confirmed.id = "msg_51"
        confirmed.seq = 51
        confirmed.delivery = .sent
        layout.apply(window.resolvePending(clientMsgID: "cm_1", confirmed: confirmed), window: window, context: context)
        #expect(window.pending.isEmpty)
        #expect(window.lastSeq == 51)
        // same row key (same layer, same measured size): the bubble settles, nothing is re-created
        let settled = layout.rows.first { $0.key == "cm_1#0" }
        #expect(settled?.height == pendingRow?.height && settled?.width == pendingRow?.width)
        #expect(layout.rows.filter { $0.key == "cm_1#0" }.count == 1)
        #expect(layout.rows.contains { if case .label("Delivered", _, _, _) = $0.kind { true } else { false } })
        var full = TranscriptLayout()
        full.rebuild(window, context: context)
        #expect(layout.snapshot == full.snapshot)
    }

    @Test func failedPendingShowsNotDelivered() {
        let context = HomeFixture.context()
        var window = HomeFixture.window(1...5)
        var layout = TranscriptLayout()
        layout.rebuild(window, context: context)
        layout.apply(window.addPending(HomeFixture.pending("cm_2", at: 500)), window: window, context: context)
        layout.apply(window.failPending(clientMsgID: "cm_2", reason: "x"), window: window, context: context)
        #expect(layout.rows.contains { if case .label("Not delivered", _, true, .danger) = $0.kind { true } else { false } })
    }

    @Test func pagingKeepsTheWindowContiguousAndBounded() {
        var window = HomeFixture.window(1001...1400, newest: 5000, oldest: 1)
        #expect(window.hasOlder && !window.atNewest)
        // a page that does not end right before firstSeq is refused
        #expect(window.prepend(HomeFixture.messages(500...599)) == .none)
        #expect(window.prepend(HomeFixture.messages(601...1000)) == .prepend(400))
        #expect(window.firstSeq == 601 && window.lastSeq == 1400)
        #expect(window.appendConfirmed(HomeFixture.messages(1402...1410)) == .none)
        #expect(window.appendConfirmed(HomeFixture.messages(1401...4000)) == .touched(IndexSet(integersIn: 800..<3400)))
        let extra = window.confirmed.count - TranscriptWindow.maxMessages
        #expect(window.evict(top: extra, bottom: 0) == .evictTop(extra))
        #expect(window.confirmed.count == TranscriptWindow.maxMessages)
        #expect(window.lastSeq - window.firstSeq + 1 == TranscriptWindow.maxMessages)
    }

    @Test func leavingTheNewestEndHidesPendingRows() {
        var window = HomeFixture.window(1...100)
        _ = window.addPending(HomeFixture.pending("cm_3", at: 9_000))
        #expect(window.count == 101)
        #expect(window.evict(top: 0, bottom: 10) == .evictBottom(11))
        #expect(window.count == 90 && !window.atNewest)
    }

    @Test func chunkedListCopyOnWriteKeepsOldValues() {
        var list = ChunkedList(Array(0..<1000))
        let copy = list
        list[5] = -1
        list.append(1000)
        list.prepend(contentsOf: [-3, -2])
        list.remove(top: 1, bottom: 1)
        #expect(copy[5] == 5 && copy.count == 1000)
        #expect(list.count == 1001 && list[0] == -2 && list[6] == -1 && list[list.count - 1] == 999)
    }
}
