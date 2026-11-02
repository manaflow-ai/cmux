@testable import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-21 on the sidebar's workspace card: it opens after a short hover, moving between
/// rows swaps its content without closing and reopening it (no flicker), and a scroll or a click
/// closes it. These drive the one hover card state machine (`HoverCardMachine`) with workspace
/// rows as the sidebar reports them: the hover delay, and `.hides(reshow:)` (the card touches
/// its row, so leaving the row and the card lets it go, but a gap between rows holds it).
struct WorkspaceHoverCardBehaviorTests {
    private static let delay = HoverCardTiming.showDelay
    private static let reshow = HoverCardTiming.reshowWindow

    private static func row(_ n: Int) -> HoverTarget {
        HoverTarget(id: HoverTargetID("ws:ws-\(n)"), window: 7, delay: delay, leave: .hides(reshow: reshow))
    }

    /// A machine with row 1's card on screen after its hover delay.
    private static func shownOnRowOne() -> HoverCardMachine {
        var machine = HoverCardMachine()
        _ = machine.reduce(.hit(row(1), moved: true))
        let token = machine.armedToken ?? -1
        _ = machine.reduce(.deadline(token: token))
        return machine
    }

    private static func hides(_ effects: [HoverCardEffect]) -> Bool { effects.contains(.hide) }

    @Test func theCardOpensOnlyAfterTheHoverDelay() throws {
        var machine = HoverCardMachine()
        let effects = machine.reduce(.hit(Self.row(1), moved: true))
        let token = try #require(machine.armedToken)
        #expect(effects == [.schedule(token: token, after: Self.delay)], "no card yet, only the delay: \(effects)")
        #expect(machine.shownTarget == nil)
        #expect(Self.delay == .milliseconds(400), "the fast cold delay (Leo 2026-11-01): \(Self.delay)")
        #expect(machine.reduce(.deadline(token: token)) == [.show(Self.row(1), sliding: false)])
        #expect(machine.shownTarget == Self.row(1))
    }

    @Test func leavingARowBeforeTheDelayShowsNothing() throws {
        var machine = HoverCardMachine()
        _ = machine.reduce(.hit(Self.row(1), moved: true))
        let stale = try #require(machine.armedToken)
        // Off the sidebar before the delay ends: the pending card is cancelled.
        #expect(machine.reduce(.hit(nil, moved: true)) == [.cancelTimer])
        #expect(machine.reduce(.deadline(token: stale)).isEmpty)
        #expect(machine.shownTarget == nil)
    }

    @Test func movingToTheNextRowSwapsTheContentWithoutClosing() {
        var machine = Self.shownOnRowOne()
        let effects = machine.reduce(.hit(Self.row(2), moved: true))
        // The one card slides to row 2 and takes its content: no hide, no new delay.
        #expect(effects == [.show(Self.row(2), sliding: true)], "\(effects)")
        #expect(machine.shownTarget == Self.row(2))
    }

    @Test func crossingAGapBetweenRowsKeepsTheCardWithinTheGrace() throws {
        var machine = Self.shownOnRowOne()
        // Between rows (a header, the gap): the card stays for the reshow window.
        let gap = machine.reduce(.hit(nil, moved: true, bridging: true))
        let token = try #require(machine.armedToken)
        #expect(gap == [.schedule(token: token, after: Self.reshow)], "\(gap)")
        #expect(!Self.hides(gap))
        #expect(machine.shownTarget == Self.row(1), "still on screen while the pointer crosses")
        // The next row within the window: the card slides over, never hidden in between.
        let next = machine.reduce(.hit(Self.row(3), moved: true))
        #expect(next == [.cancelTimer, .show(Self.row(3), sliding: true)], "\(next)")
        #expect(machine.shownTarget == Self.row(3))
    }

    @Test func aGapLongerThanTheGraceLetsTheCardGo() throws {
        var machine = Self.shownOnRowOne()
        _ = machine.reduce(.hit(nil, moved: true, bridging: true))
        let token = try #require(machine.armedToken)
        _ = machine.reduce(.pointerOnCard(false))
        #expect(Self.hides(machine.reduce(.deadline(token: token))))
        #expect(machine.shownTarget == nil)
    }

    @Test func comingBackSoonAfterItHidShowsAtOnce() throws {
        var machine = Self.shownOnRowOne()
        // Off the sidebar (not between rows): it hides at once.
        #expect(Self.hides(machine.reduce(.hit(nil, moved: true))))
        // Back on a row within the reshow window: no second wait.
        let back = machine.reduce(.hit(Self.row(2), moved: true))
        #expect(back == [.cancelTimer, .show(Self.row(2), sliding: false)], "\(back)")
    }

    @Test func aScrollClosesTheCard() {
        var machine = Self.shownOnRowOne()
        #expect(Self.hides(machine.reduce(.dismiss(.scrollWheel))))
        #expect(machine.shownTarget == nil)
        // The row left under the still pointer brings no card back.
        #expect(machine.reduce(.hit(Self.row(1), moved: false)).isEmpty)
        #expect(machine.activeTarget == nil)
    }

    @Test func aScrollInProgressKeepsCardsAway() {
        var machine = Self.shownOnRowOne()
        #expect(Self.hides(machine.reduce(.suppress(.scroll))))
        #expect(machine.reduce(.hit(Self.row(2), moved: true)).isEmpty)
        #expect(machine.activeTarget == nil)
    }

    /// The card sits beside the sidebar, never over the row it describes: mid-list, near the
    /// screen's bottom (clamped up), near its top, and with the sidebar at the screen's right edge.
    @Test func theCardNeverCoversItsRow() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 280, height: 160)
        let rows = [CGRect(x: 8, y: 600, width: 224, height: 32), CGRect(x: 8, y: 40, width: 224, height: 32),
                    CGRect(x: 8, y: 850, width: 224, height: 32), CGRect(x: 1200, y: 400, width: 232, height: 32)]
        for row in rows {
            let geometry = HoverCardEscapeGeometry(anchor: row, cardSize: size, visible: screen.insetBy(dx: 8, dy: 8))
            #expect(!geometry.card.intersects(row), "row \(row): card \(geometry.card)")
            #expect(geometry.card.minX >= row.maxX || geometry.card.maxX <= row.minX, "beside the row: \(geometry.card)")
        }
    }

    @Test func aClickClosesTheCardUntilThePointerMovesOn() {
        var machine = Self.shownOnRowOne()
        #expect(Self.hides(machine.reduce(.dismiss(.click))))
        #expect(machine.shownTarget == nil)
        // The pointer resting on the clicked row starts no new card.
        #expect(machine.reduce(.hit(Self.row(1), moved: false)).isEmpty)
        #expect(machine.activeTarget == nil)
        // Another row starts one again, after the delay.
        let next = machine.reduce(.hit(Self.row(2), moved: true))
        #expect(next.contains { if case .schedule(_, let after) = $0 { after == Self.delay } else { false } }, "\(next)")
    }

    /// Leo 2026-11-01: "for my mouse to be able to reliably go across them". A pointer heading
    /// from its row into the card beside it, across the next row, keeps the card (the safe
    /// triangle); the row it crosses takes the card only if the pointer stops on it.
    @Test func aimingIntoTheCardAcrossAnotherRowKeepsTheCard() throws {
        var machine = Self.shownOnRowOne()
        let aimed = machine.reduce(.hit(Self.row(2), moved: true, aiming: true))
        #expect(!aimed.contains { if case .show = $0 { true } else { false } }, "crossing row 2 swapped the card: \(aimed)")
        #expect(machine.shownTarget == Self.row(1))
        // Still heading in, across row 3: the aim restarts.
        _ = machine.reduce(.hit(Self.row(3), moved: true, aiming: true))
        #expect(machine.shownTarget == Self.row(1))
        // On the card: no target; it stays while the pointer rests there.
        _ = machine.reduce(.hit(nil, moved: true, bridging: true))
        _ = machine.reduce(.pointerOnCard(true))
        let token = try #require(machine.armedToken)
        _ = machine.reduce(.deadline(token: token))
        #expect(machine.shownTarget == Self.row(1), "the card went with the pointer on it")
    }

    @Test func stoppingOnACrossedRowHandsItTheCard() throws {
        var machine = Self.shownOnRowOne()
        _ = machine.reduce(.hit(Self.row(2), moved: true, aiming: true))
        _ = machine.reduce(.pointerOnCard(false))
        let token = try #require(machine.armedToken)
        #expect(machine.reduce(.deadline(token: token)) == [.show(Self.row(2), sliding: true)])
        #expect(machine.shownTarget == Self.row(2))
    }

    /// Moving down the list (not toward the card) still swaps at once.
    @Test func aRowReachedWithoutAimingSwapsAtOnce() {
        var machine = Self.shownOnRowOne()
        #expect(machine.reduce(.hit(Self.row(2), moved: true, aiming: false)) == [.show(Self.row(2), sliding: true)])
    }
}
