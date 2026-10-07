import CmuxHomeCore
import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct ScrollAnchoringTests {
    private func rowY(_ c: HomeController, _ key: String) -> CGFloat? {
        guard let i = c.scene.model.index[key] else { return nil }
        return c.scene.windowY(contentY: c.scene.layout.contentTop(i))
    }

    private func lastRowBottom(_ c: HomeController) -> CGFloat {
        let last = c.scene.model.count - 1
        return c.scene.windowY(contentY: c.scene.layout.contentTop(last) + c.scene.model.rows[last].spec.height)
    }

    @Test func startsPinnedWithTheNewestRowOnTheAnchor() {
        let c = Fixtures.controller(height: 600)
        c.update(items: Fixtures.items(Fixtures.conversation(60)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.isPinnedToNewest)
        #expect(abs(lastRowBottom(c) - c.scene.anchorY) < 0.01)
    }

    /// An older page arrives above while the user reads mid-transcript: the
    /// rows on screen do not move.
    @Test func prependKeepsTheViewportRows() throws {
        let c = Fixtures.controller(height: 600)
        let newest = Fixtures.conversation(60, firstSeq: 41)
        c.update(items: Fixtures.items(newest), summary: Fixtures.summary(), typing: [], hasOlder: true)
        c.handle(.scroll(deltaY: 400, phase: .changed, momentum: .none))
        #expect(!c.isPinnedToNewest)
        let anchor = try #require(c.scene.visibleAnchor())
        c.update(items: Fixtures.items(Fixtures.conversation(40) + newest), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let y = try #require(rowY(c, anchor.key))
        #expect(abs(y - anchor.y) < 0.01)
        #expect(!c.scene.isAnimating, "a page load does not animate")
    }

    /// A new message at the end does not move what the user is reading.
    @Test func appendWhileScrolledUpKeepsTheViewportRows() throws {
        let c = Fixtures.controller(height: 600)
        let messages = Fixtures.conversation(60)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        c.handle(.scroll(deltaY: 700, phase: .changed, momentum: .none))
        let anchor = try #require(c.scene.visibleAnchor())
        let incoming = Fixtures.message(61, Fixtures.chief, "New results are in.")
        c.update(items: Fixtures.items(messages + [incoming]), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let y = try #require(rowY(c, anchor.key))
        #expect(abs(y - anchor.y) < 0.01)
        #expect(!c.isPinnedToNewest)
    }

    /// Pinned: the new row lands on the anchor and the rows above move up.
    @Test func appendWhilePinnedFollowsTheNewestRow() {
        let c = Fixtures.controller(height: 600)
        let messages = Fixtures.conversation(20)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let incoming = Fixtures.message(21, Fixtures.chief, "New results are in.")
        c.update(items: Fixtures.items(messages + [incoming]), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.isPinnedToNewest)
        #expect(abs(lastRowBottom(c) - c.scene.anchorY) < 0.01)
        #expect(c.scene.model.rows.last?.spec.key == "part:key_21:0")
        #expect(c.scene.isAnimating, "the rows above spring up")
    }

    @Test func reachingTheOldestRowAsksForOlderOnce() {
        let c = Fixtures.controller(height: 600)
        var asks = 0
        c.onNeedsOlder = { asks += 1 }
        c.update(items: Fixtures.items(Fixtures.conversation(60, firstSeq: 41)), summary: Fixtures.summary(), typing: [], hasOlder: true)
        c.handle(.scroll(deltaY: 100_000, phase: .changed, momentum: .none))
        c.handle(.scroll(deltaY: -10, phase: .changed, momentum: .none))
        #expect(asks == 1)
        #expect(c.scene.offset >= c.scene.minOffset)
    }

    /// A first page that does not fill the viewport cannot scroll, so it asks at once.
    @Test func shortFirstPageAsksForOlder() {
        let c = Fixtures.controller(height: 900)
        var asks = 0
        c.onNeedsOlder = { asks += 1 }
        c.update(items: Fixtures.items(Fixtures.conversation(3, firstSeq: 50)), summary: Fixtures.summary(), typing: [], hasOlder: true)
        #expect(asks == 1)
    }

    @Test func scrollingBackDownRepins() {
        let c = Fixtures.controller(height: 600)
        c.update(items: Fixtures.items(Fixtures.conversation(60)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        c.handle(.scroll(deltaY: 300, phase: .changed, momentum: .none))
        #expect(!c.isPinnedToNewest)
        c.handle(.scroll(deltaY: -10_000, phase: .changed, momentum: .none))
        #expect(c.isPinnedToNewest)
        #expect(c.scene.offset == c.scene.pinnedOffset)
    }

    /// Hosts without system momentum step a decaying fling until it stops.
    @Test func momentumDecaysAndStops() {
        let c = Fixtures.controller(height: 600)
        c.update(items: Fixtures.items(Fixtures.conversation(200)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let start = c.scene.offset
        c.handle(.fling(velocity: 2000))
        var t = CACurrentMediaTime() + 1.0 / 120
        var frames = 0
        while c.stepMomentum(timestamp: t), frames < 2000 {
            t += 1.0 / 120
            frames += 1
        }
        #expect(frames > 10 && frames < 2000)
        #expect(c.scene.offset < start)
        #expect(!c.stepMomentum(timestamp: t + 1))
    }
}
