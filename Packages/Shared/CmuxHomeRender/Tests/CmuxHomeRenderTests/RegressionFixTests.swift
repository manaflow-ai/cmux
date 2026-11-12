import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// The iOS host's regressions (lane 14): run grouping and sender names,
/// text scale, scroll to a message.
@MainActor
@Suite struct RegressionFixTests {
    static let ana = ParticipantID("user_ana")

    private func groupSummary() -> ConversationSummary {
        ConversationSummary(id: Fixtures.conversation,
                            participants: [Participant(id: Fixtures.me, kind: .human, displayName: "Me"),
                                           Participant(id: Fixtures.chief, kind: .agent, displayName: "Chief", agentClass: .chief),
                                           Participant(id: Self.ana, kind: .human, displayName: "Ana")],
                            createdAt: Fixtures.start, updatedAt: Fixtures.start, readCursors: [:])
    }

    private func run() -> [Message] {
        [Fixtures.message(1, Fixtures.chief, "One", at: 0),
         Fixtures.message(2, Fixtures.chief, "Two", at: 120),
         Fixtures.message(3, Fixtures.chief, "Three", at: 240),
         Fixtures.message(4, Self.ana, "Hi", at: 260)]
    }

    private func parts(_ c: HomeController) -> [RowSpec] { c.scene.model.rows.map(\.spec).filter { $0.partRow != nil } }

    @Test func aRunHasTightGapsAndOneTail() {
        let c = Fixtures.controller(height: 800)
        c.update(items: Fixtures.items(run()), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let p = parts(c)
        #expect(p.count == 4)
        #expect(p.map { $0.partRow?.tail ?? false } == [false, false, true, true], "a tail only on the last bubble of each run")
        #expect(p[1].gap == 3 && p[2].gap == 3, "bubbles of one run sit close")
    }

    @Test func groupConversationsNameTheFirstBubbleOfEachRun() {
        let c = Fixtures.controller(height: 800)
        c.update(items: Fixtures.items(run()), summary: groupSummary(), typing: [], hasOlder: false)
        let names: [String] = c.scene.model.rows.compactMap { if case .senderName(let n) = $0.spec.kind { n } else { nil } }
        #expect(names == ["Chief", "Ana"])
        let direct = Fixtures.controller(height: 800)
        direct.update(items: Fixtures.items(run()), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(!direct.scene.model.rows.contains { if case .senderName = $0.spec.kind { true } else { false } })
    }

    @Test func textScaleScalesTheTranscriptAndDrawsSharp() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        let messages = Fixtures.conversation(6)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let before = try #require(c.hits(in: CGRect(x: 0, y: 0, width: 628, height: 900)).last)
        c.textScale = 17.0 / 13.0
        await c.bitmapsSettled()
        let after = try #require(c.hits(in: CGRect(x: 0, y: 0, width: 628, height: 900)).last)
        let ratio: CGFloat = after.bubble.height / before.bubble.height
        #expect(abs(ratio - 17.0 / 13.0) < 0.05, "bubble height grows with the text")
        #expect(c.size == CGSize(width: 628, height: 900), "the host keeps its viewport size")
        let scales = c.scene.visible.values.map(\.bitmap.contentsScale)
        #expect(scales.allSatisfy { abs($0 - 2 * 17.0 / 13.0) < 0.001 }, "bitmaps match the zoomed pixel density")
        #expect(c.hit(at: CGPoint(x: after.bubble.midX, y: after.bubble.midY))?.item == after.item)
    }

    @Test func scrollToAMessageBringsItIntoView() throws {
        let c = Fixtures.controller(width: 628, height: 700)
        let messages = Fixtures.conversation(80)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        var published: [HomeController.ScrollGeometry] = []
        c.onScrollGeometryChange = { published.append($0) }
        let target = messages[10].clientMessageID
        #expect(c.scroll(to: target, anchor: .center))
        let frame = try #require(c.contentFrame(for: target))
        let g = c.scrollGeometry
        #expect(frame.minY >= g.offset && frame.maxY <= g.offset + 700, "the message is on screen")
        #expect(!c.isPinnedToNewest)
        #expect(published.last == g, "the host scroll view follows")
        #expect(!c.scroll(to: IdempotencyKey("missing")))
        #expect(c.item(withSeq: messages[10].seq) == target)
    }
}
