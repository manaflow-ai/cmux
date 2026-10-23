import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// A send that got no answer after it reached the owner renders "May Not
/// Have Been Delivered" (past tense: it may be there already); a send that
/// never reached the owner, or was refused, renders "Not Delivered".
@MainActor
@Suite struct FailedLabelTests {
    private func failedSend(mayHaveBeenDelivered: Bool) -> PendingIntent {
        var entry = PendingIntent(intent: HomeIntent(key: IdempotencyKey("key_failed"),
                                                     op: .sendMessage(conversation: Fixtures.conversation, parts: [.text("lost")])),
                                  state: .failed(.indeterminate))
        entry.mayHaveBeenDelivered = mayHaveBeenDelivered
        return entry
    }

    private func labels(_ c: HomeController) -> [String] {
        c.scene.model.rows.compactMap { if case .failedLabel(let text) = $0.spec.kind { text } else { nil } }
    }

    @Test func anUnansweredSendThatReachedTheOwnerSaysItMayHaveBeenDelivered() async throws {
        let c = Fixtures.controller()
        c.update(items: Fixtures.items(Fixtures.conversation(4), pending: [failedSend(mayHaveBeenDelivered: true)]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(labels(c) == ["May Not Have Been Delivered"])
        let item = try #require(c.accessibilityItems().first { $0.id == "failed:key_failed" })
        #expect(item.label == "May Not Have Been Delivered")
        await c.scene.bitmaps.settled()
        let row = try #require(c.scene.visible["failed:key_failed"])
        #expect(row.bitmap.contents != nil, "the label row draws")
    }

    @Test func aSendThatNeverReachedTheOwnerSaysNotDelivered() {
        let c = Fixtures.controller()
        c.update(items: Fixtures.items(Fixtures.conversation(4), pending: [failedSend(mayHaveBeenDelivered: false)]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(labels(c) == ["Not Delivered"])
    }
}
