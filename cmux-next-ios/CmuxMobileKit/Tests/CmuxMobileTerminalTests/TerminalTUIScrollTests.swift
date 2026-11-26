import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// T-SCROLL-12: in a full-screen app the page is pinned and a vertical drag
/// scrolls the app, like a Mac trackpad in Ghostty. The drag is an ordinary
/// UIScrollView scroll (Leo: "treat the scroll like any pedestrian scroll"):
/// each move of its offset is one precise wheel delta in points, 1:1
/// (natural direction: a finger moving down lowers the offset and scrolls
/// toward older content), its deceleration's are momentum; the surface
/// scales them to pixels and Ghostty decides what the app receives (wheel
/// reports or arrows).
@Suite struct TerminalTUIScrollTests {
    typealias Wheel = TerminalTUIScroll.Wheel

    @Test func aDragDownIsAWheelUp() {
        var scroll = TerminalTUIScroll()
        scroll.reset(offset: 1000)
        // A finger moving down lowers the offset: older content.
        #expect(scroll.scrolled(to: 990, tracking: true) == Wheel(dy: 10, momentum: .none))
        // Deltas, not the running offset.
        #expect(scroll.scrolled(to: 986, tracking: true) == Wheel(dy: 4, momentum: .none))
        #expect(scroll.scrolled(to: 996, tracking: true) == Wheel(dy: -10, momentum: .none))
    }

    /// Leo: "treat the scroll like any pedestrian scroll": the wheel moves
    /// exactly as far as the scroll view, at any speed (no trackpad gain).
    @Test func theWheelMovesOneToOneWithTheScrollView() {
        var scroll = TerminalTUIScroll()
        scroll.reset(offset: 0)
        var total: CGFloat = 0, offset: CGFloat = 0
        for step in [1, 40, 160, 3, 90] as [CGFloat] {
            offset -= step
            total += scroll.scrolled(to: offset, tracking: true)?.dy ?? 0
        }
        #expect(total == 294)
    }

    @Test func noMovementSendsNothing() {
        var scroll = TerminalTUIScroll()
        scroll.reset(offset: 50)
        #expect(scroll.scrolled(to: 50, tracking: true) == nil)
        _ = scroll.scrolled(to: 45, tracking: false)
        #expect(scroll.scrolled(to: 45, tracking: false) == nil)
    }

    @Test func aNewDragStartsFromItsOffset() {
        var scroll = TerminalTUIScroll()
        scroll.reset(offset: 0)
        _ = scroll.scrolled(to: -50, tracking: true)
        scroll.reset(offset: 2000)
        #expect(scroll.scrolled(to: 2005, tracking: true) == Wheel(dy: -5, momentum: .none))
    }

    /// The scroll view's deceleration after the finger lifts is a macOS
    /// momentum phase: began, changed..., ended once.
    @Test func theDecelerationIsTheMomentumPhase() {
        var scroll = TerminalTUIScroll()
        scroll.reset(offset: 0)
        #expect(scroll.scrolled(to: -30, tracking: true) == Wheel(dy: 30, momentum: .none))
        #expect(scroll.scrolled(to: -50, tracking: false) == Wheel(dy: 20, momentum: .began))
        #expect(scroll.scrolled(to: -60, tracking: false) == Wheel(dy: 10, momentum: .changed))
        #expect(scroll.scrolled(to: -61, tracking: false) == Wheel(dy: 1, momentum: .changed))
        #expect(scroll.ended() == Wheel(dy: 0, momentum: .ended))
        #expect(scroll.ended() == nil)
        // The next fling begins a new phase.
        #expect(scroll.scrolled(to: -40, tracking: false) == Wheel(dy: -21, momentum: .began))
    }

    @Test func aDragWithNoFlingSendsNoEnd() {
        var scroll = TerminalTUIScroll()
        scroll.reset(offset: 0)
        _ = scroll.scrolled(to: 12, tracking: true)
        #expect(scroll.ended() == nil)
    }

    @Test func scrollModsArePreciseAndCarryTheMomentumPhase() {
        // Ghostty's packed ScrollMods: bit 0 precision, bits 1-3 momentum.
        #expect(TerminalTUIScroll.mods(.none) == 0b0001)
        #expect(TerminalTUIScroll.mods(.began) == 0b0011)
        #expect(TerminalTUIScroll.mods(.changed) == 0b0111)
        #expect(TerminalTUIScroll.mods(.ended) == 0b1001)
    }

    @Test func onlyAVerticalDragScrollsTheApp() {
        #expect(TerminalTUIScroll.takesDrag(motion: CGPoint(x: 10, y: 200)))
        #expect(TerminalTUIScroll.takesDrag(motion: CGPoint(x: 0, y: -80)))
        #expect(!TerminalTUIScroll.takesDrag(motion: CGPoint(x: 300, y: 40)))
        #expect(!TerminalTUIScroll.takesDrag(motion: .zero))
    }
}
