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

    private static let rect = NSRect(x: 0, y: 0, width: 10, height: 10)

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func bandWindow() -> BandWindow {
        let window = BandWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
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
        let sidebar = Self.window()
        let windows: [Int: NSWindow] = [101: band, 7: sidebar]
        let top = PointerTopWindow.number(at: NSPoint(x: 5, y: 5), below: Self.stack([101, 7]), window: { windows[$0] })
        #expect(top == 7, "the band's window (101) hid the sidebar's window (7) from the hover")
    }

    /// The card itself still covers what is under it: over the card the update card is not hovered.
    @Test func theCardItselfStillCovers() {
        let band = Self.bandWindow()
        band.passes = { _ in false }
        let windows: [Int: NSWindow] = [101: band, 7: Self.window()]
        #expect(PointerTopWindow.number(at: .zero, below: Self.stack([101, 7]), window: { windows[$0] }) == 101)
    }

    /// Any other window (another app's, a plain panel) covers as before.
    @Test func anOrdinaryWindowCovers() {
        let windows: [Int: NSWindow] = [55: Self.window(), 7: Self.window()]
        #expect(PointerTopWindow.number(at: .zero, below: Self.stack([55, 7]), window: { windows[$0] }) == 55)
        #expect(PointerTopWindow.number(at: .zero, below: Self.stack([900, 7]), window: { windows[$0] }) == 900,
                "a window of another app (not in the list) covers")
    }

    /// Bands that pass through to each other end: the look-through is bounded.
    @Test func passThroughsAreBounded() {
        let band = Self.bandWindow()
        let top = PointerTopWindow.number(at: .zero, below: { _, _ in 101 }, window: { _ in band })
        #expect(top == 101)
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// The real notes card, presented beside the update card as the sidebar shows it: its band passes
    /// the pointer, its card does not, and a click-through card passes it everywhere.
    @Test(.enabled("the card's window is placed on a screen") { await Self.hasDisplay() })
    func theNotesCardsBandPassesThePointer() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first).visibleFrame
        let parent = NSWindow(contentRect: NSRect(x: screen.minX + 100, y: screen.minY + 100, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let panel = HoverCardPanel()
        defer {
            panel.closeAfterTest()
            parent.close()
        }
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 300), body.heightAnchor.constraint(equalToConstant: 200)])
        // The update card at the sidebar's bottom.
        let updateCard = CGRect(x: parent.frame.minX + 12, y: parent.frame.minY + 60, width: 260, height: 48)
        panel.present(body: body, anchor: updateCard, placement: .beside, parent: parent, themeAnchor: nil, sliding: false,
                      interactive: true, applyTheme: {})
        let card = panel.presentedCardFrame
        // The update card's top right corner, where its x is: inside the notes window's frame, outside its card.
        let corner = NSPoint(x: updateCard.maxX - 8, y: updateCard.maxY - 8)
        #expect(panel.frame.contains(corner), "the premise: the notes window's band covers the update card's x (\(panel.frame) vs \(corner))")
        #expect(!card.contains(corner))
        #expect(panel.passesPointer(atScreen: corner), "the band hid the update card's x from its hover")
        #expect(!panel.passesPointer(atScreen: NSPoint(x: card.midX, y: card.midY)), "the card itself covers")
        #expect(panel.bandRelay != nil, "an interactive card relays band moves to its parent's hover")

        panel.present(body: body, anchor: updateCard, placement: .beside, parent: parent, themeAnchor: nil, sliding: false,
                      interactive: false, applyTheme: {})
        #expect(panel.passesPointer(atScreen: NSPoint(x: card.midX, y: card.midY)), "a click-through card passes the pointer")
    }
}
