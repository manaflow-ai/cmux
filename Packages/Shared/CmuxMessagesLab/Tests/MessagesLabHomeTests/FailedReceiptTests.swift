import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The label under my failed message, in MessagesLab's receipt style and
/// place: "May Not Have Been Delivered" when the send reached the owner and
/// got no answer after every resend (`TranscriptItem.mayHaveBeenDelivered`),
/// else "Not Delivered".
@MainActor @Suite(.serialized) struct FailedReceiptTests {
    let me = Fixture2.me

    @Test func aFailedSendSaysWhetherItMayHaveBeenDelivered() {
        let (p, c) = Fixture2.projection()
        let refused = TranscriptItem(key: IdempotencyKey("refused"), seq: nil, author: me, parts: [.text("Refused")],
                                     createdAt: Fixture2.start.addingTimeInterval(400), delivery: .notDelivered(.notAuthorized))
        var unanswered = TranscriptItem(key: IdempotencyKey("unanswered"), seq: nil, author: me, parts: [.text("Did it go?")],
                                        createdAt: Fixture2.start.addingTimeInterval(430), delivery: .notDelivered(.ownerUnreachable))
        unanswered.mayHaveBeenDelivered = true
        p.apply(items: Fixture2.history(3) + [refused, unanswered], summary: Fixture2.summary(lastSeq: 3), typing: [], hasOlder: false)
        func label(_ key: String) -> String? {
            guard let row = c.demo.model.rows.first(where: { $0.spec.key == "failed:\(key)" }),
                  case let .label(text, outgoing, color) = row.spec.kind, outgoing, color == .failure else { return nil }
            return text
        }
        #expect(label("unanswered") == "May Not Have Been Delivered")
        #expect(label("refused") == "Not Delivered")
    }

    @Test func theLabelFollowsTheRowWhenItBecomesUnanswered() {
        let (p, c) = Fixture2.projection()
        var item = TranscriptItem(key: IdempotencyKey("send"), seq: nil, author: me, parts: [.text("Hello")],
                                  createdAt: Fixture2.start.addingTimeInterval(400), delivery: .notDelivered(.ownerUnreachable))
        p.apply(items: Fixture2.history(2) + [item], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        item.mayHaveBeenDelivered = true
        p.apply(items: Fixture2.history(2) + [item], summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        let row = c.demo.model.rows.first { $0.spec.key == "failed:send" }
        guard case let .label(text, _, _)? = row?.spec.kind else { Issue.record("no failed label"); return }
        #expect(text == "May Not Have Been Delivered")
    }
}
