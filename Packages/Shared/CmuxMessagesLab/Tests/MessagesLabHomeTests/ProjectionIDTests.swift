import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The Chief's messages carry keys with colons ("turn:s1:2", "work:<session>:<n>").
/// MessagesLab's row keys are "kind:messageID[:part]" and RowBuilder.owner splits
/// at the first two colons, so a colon in a message id hid that message's rows
/// from the incremental row update: it kept every row and appended the new tail
/// again (hmchief6, light theme, 1300 pt: the newest bubbles drawn again at the
/// top, blurred under the header).
@MainActor @Suite(.serialized) struct ProjectionIDTests {
    let them = Fixture2.them, me = Fixture2.me

    @Test func chiefKeysWithColonsKeepOneRowPerPart() throws {
        let (p, c) = Fixture2.projection()
        c.host.layoutSubtreeIfNeeded()
        var items = [Fixture2.item(1, me, "Hello", key: "preflight-1"), Fixture2.item(2, them, "Hi there", key: "turn:s1:2")]
        p.apply(items: items, summary: Fixture2.summary(lastSeq: 2), typing: [], hasOlder: false)
        for seq in 3...5 {
            items.append(Fixture2.item(Seq(seq), seq % 2 == 0 ? them : me, "Message \(seq)", key: seq % 2 == 0 ? "turn:s1:\(seq)" : "preflight-\(seq)"))
            p.apply(items: items, summary: Fixture2.summary(lastSeq: Seq(seq)), typing: [], hasOlder: false)
        }
        let keys = c.demo.model.rows.map(\.spec.key)
        #expect(keys.count == Set(keys).count, "duplicate rows: \(keys)")
        #expect(keys.filter { $0.hasPrefix("part:") }.count == 5, "one part row per message: \(keys)")
        // Ids still round-trip: a tapback on a Chief message finds its item.
        let chief = try #require(c.store.state.conversation.messages.first { $0.senderId == them.rawValue })
        #expect(RowBuilder.owner("part:\(chief.id):0") == Substring(chief.id))
    }
}
