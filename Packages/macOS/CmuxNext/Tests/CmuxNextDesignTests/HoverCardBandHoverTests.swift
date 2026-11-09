import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Aziz 2026-11-09 (screenshot of the sidebar's "Updated to Nightly" card with its notes open
/// beside it): "The x here doesnt appear when the cursor is in the top right, it's weird because in
/// certain hover positions the x doesnt appear whiel it does in others." The notes card's window
/// keeps a clear band (`HoverCardPanel.windowMargin`) around the card, and the band reaches over the
/// update card's top right corner. The window server names the band's window as the one under the
/// pointer there, so `PointerHover.isTopmost` read the update card as covered and hid its x.
@Suite(.closesItsWindows)
@MainActor struct HoverCardBandHoverTests {
    /// A window that passes the pointer through wherever `passes` says.
    private final class BandWindow: NSWindow, PointerClearBandWindow {
        var passes: (NSPoint) -> Bool = { _ in true }
        func passesPointer(atScreen screenPoint: NSPoint) -> Bool { passes(screenPoint) }
    }

    private static func bandWindow() -> BandWindow {
        let window = BandWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                                backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The window server's stack at a point, front first, as `NSWindow.windowNumber(at:below…:)` answers it.
    private static func stack(_ numbers: [Int]) -> (NSPoint, Int) -> Int {
        { _, below in
            guard below != 0 else { return numbers.first ?? 0 }
            guard let index = numbers.firstIndex(of: below), index + 1 < numbers.count else { return 0 }
            return numbers[index + 1]
        }
    }

    /// The pointer in a hover card's clear band is over the window below: the update card's own.
    @Test func aClearBandPassesThePointerToTheWindowBelow() {
        let band = Self.bandWindow()
        defer { band.closeAfterTest() }
        let top = PointerTopWindow.number(at: NSPoint(x: 5, y: 5), below: Self.stack([101, 7]), window: { $0 == 101 ? band : nil })
        #expect(top == 7, "the band's window (101) hid the sidebar's window (7) from the hover")
    }

    /// The card itself still covers what is under it: over the card the update card is not hovered.
    @Test func theCardItselfStillCovers() {
        let band = Self.bandWindow()
        defer { band.closeAfterTest() }
        band.passes = { _ in false }
        #expect(PointerTopWindow.number(at: .zero, below: Self.stack([101, 7]), window: { $0 == 101 ? band : nil }) == 101)
    }

    /// Any other window (another app's, or one of ours that is no band) covers as before.
    @Test func anOrdinaryWindowCovers() {
        #expect(PointerTopWindow.number(at: .zero, below: Self.stack([55, 7]), window: { _ in nil }) == 55)
    }

    /// Bands that pass through to each other end: the look-through is bounded.
    @Test func passThroughsAreBounded() {
        let band = Self.bandWindow()
        defer { band.closeAfterTest() }
        #expect(PointerTopWindow.number(at: .zero, below: { _, _ in 101 }, window: { _ in band }) == 101)
    }
}
