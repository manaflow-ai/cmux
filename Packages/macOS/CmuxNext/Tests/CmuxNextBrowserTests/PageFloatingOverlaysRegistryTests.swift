import AppKit
@testable import CmuxNextBrowser
import Testing

/// The cards over a page (`PageFloatingOverlays`) follow only their page's
/// window's page updates (`ChildPageGeometryRegistry`). Before, every card observed the page
/// update request of every window; now it registers with its page's window, moves to the new
/// window's registry when the page changes window, and leaves when its last card goes.
@MainActor
@Suite struct PageFloatingOverlaysRegistryTests {
    /// A card that sizes itself, as the notice pill does.
    final class Card: NSView, PageFloatingCard {
        func cardSize(maxWidth: CGFloat) -> CGSize { CGSize(width: min(120, maxWidth), height: 32) }
    }

    func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func cardsFollowOnlyTheirPagesWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        defer { windowA.close(); windowB.close() }
        let registryA = ChildPageGeometryRegistry.of(windowA)
        let registryB = ChildPageGeometryRegistry.of(windowB)
        let page = NSView(frame: NSRect(x: 20, y: 30, width: 400, height: 300))
        windowA.contentView?.addSubview(page)
        let overlays = PageFloatingOverlays(page: page)
        let card = Card(frame: .zero)
        overlays.add(card)
        overlays.sync()
        #expect(registryA.count == 1, "the card follows its page's window")
        #expect(registryB.count == 0)
        #expect(card.superview != nil, "the card shows over the page")

        // The page hides with no chrome sync: only its own window's request reaches the card,
        // which then takes the card off screen.
        page.isHidden = true
        windowB.updateBrowserPageGeometry()
        #expect(card.superview != nil, "another window's request does not sync the card")
        #expect(windowA.updateBrowserPageGeometry() == 0, "a card reports no page change")
        #expect(card.superview == nil, "its window's request synced the card")

        // The page moves to window B; the chrome syncs there.
        page.isHidden = false
        windowB.contentView?.addSubview(page)
        overlays.sync()
        #expect(registryA.count == 0, "the card left window A's registry")
        #expect(registryB.count == 1)
        #expect(card.superview != nil)
        page.isHidden = true
        windowA.updateBrowserPageGeometry()
        #expect(card.superview != nil, "window A no longer reaches the card")
        windowB.updateBrowserPageGeometry()
        #expect(card.superview == nil, "window B's request syncs the card")

        overlays.remove(card)
        #expect(registryB.count == 0, "no card left: no registration")
    }
}
