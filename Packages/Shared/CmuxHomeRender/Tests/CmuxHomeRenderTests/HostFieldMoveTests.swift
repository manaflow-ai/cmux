import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// A host field moved by the keyboard (plans/cmux-next/ios-keyboard.md K2):
/// the host animates the move on the keyboard's own curve, so the core moves
/// the rows at once, adds no spring, and reports how far the rows moved.
@MainActor
@Suite struct HostFieldMoveTests {
    private func loaded(height: CGFloat = 800) -> HomeController {
        let c = Fixtures.controller(width: 402, height: height)
        c.setHostedField(CGRect(x: 8, y: height - 44, width: 386, height: 36))
        c.update(items: Fixtures.items(Fixtures.conversation(30)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        return c
    }

    private func lastRowBottom(_ c: HomeController) -> CGFloat {
        let last = c.scene.model.count - 1
        return c.scene.windowY(contentY: c.scene.layout.contentTop(last) + c.scene.model.rows[last].spec.height)
    }

    @Test func anInstantMoveWhilePinnedMovesTheRowsWithTheFieldAndAddsNoSpring() {
        let c = loaded()
        #expect(c.isPinnedToNewest)
        let before = lastRowBottom(c)
        let entriesBefore = c.scene.ledger.entries.values.map(\.count).reduce(0, +)
        let delta = c.setHostedField(CGRect(x: 8, y: 800 - 44 - 300, width: 386, height: 36), animated: false)
        #expect(abs(delta - 300) < 0.5, "rows moved up by the field's move (\(delta))")
        #expect(abs((before - lastRowBottom(c)) - 300) < 0.5, "the last row is above the moved field")
        #expect(c.scene.ledger.entries.values.map(\.count).reduce(0, +) == entriesBefore, "no spring for a host-animated move")
        #expect(c.isPinnedToNewest)
    }

    @Test func anInstantMoveWhileScrolledUpKeepsTheRowsAndReportsNoMove() {
        let c = loaded()
        c.hostScrolled(to: c.scrollGeometry.offset - 400)
        #expect(!c.isPinnedToNewest)
        let delta = c.setHostedField(CGRect(x: 8, y: 800 - 44 - 300, width: 386, height: 36), animated: false)
        #expect(abs(delta) < 0.5, "a scrolled-up transcript keeps its rows (\(delta))")
    }

    @Test func theAnimatedMoveStillSpringsTheRows() {
        let c = loaded()
        let entriesBefore = c.scene.ledger.entries.values.map(\.count).reduce(0, +)
        c.setHostedField(CGRect(x: 8, y: 800 - 44 - 300, width: 386, height: 36))
        #expect(c.scene.ledger.entries.values.map(\.count).reduce(0, +) > entriesBefore)
    }
}
