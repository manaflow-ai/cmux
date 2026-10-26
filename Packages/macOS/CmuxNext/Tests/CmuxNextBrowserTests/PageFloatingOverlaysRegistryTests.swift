import AppKit
@testable import CmuxNextBrowser
import Testing

/// p06-scheduler-046: the cards over a page (`PageFloatingOverlays`) follow only their page's
/// window's page updates (`ChildPageGeometryRegistry`). Before, every card observed the page
/// update request of every window; now it registers with its page's window, moves to the new
/// window's registry when the page changes window, and leaves when its last card goes.
@MainActor
@Suite struct PageFloatingOverlaysRegistryTests {
    /// A window with the app window's page registry (`ShellWindow`).
    final class PagesWindow: NSWindow, ChildPageGeometryHosting {
        let childPageGeometry = ChildPageGeometryRegistry()
    }

    func makeWindow() -> PagesWindow {
        _ = NSApplication.shared
        let window = PagesWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: .borderless,
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A card that sizes itself, as the notice pill does.
    func makeCard() -> NSView {
        let card = NSView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 120),
            card.heightAnchor.constraint(equalToConstant: 32),
        ])
        return card
    }

    @Test func cardsFollowOnlyTheirPagesWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        defer { windowA.close(); windowB.close() }
        let page = NSView(frame: NSRect(x: 20, y: 30, width: 400, height: 300))
        windowA.contentView?.addSubview(page)
        let overlays = PageFloatingOverlays(page: page)
        let card = makeCard()
        overlays.add(card)
        overlays.sync()
        #expect(windowA.childPageGeometry.count == 1, "the card follows its page's window")
        #expect(windowB.childPageGeometry.count == 0)
        #expect(card.superview != nil, "the card shows over the page")

        // The page hides with no chrome sync: only its own window's request reaches the card,
        // which then takes the card off screen.
        page.isHidden = true
        windowB.childPageGeometry.pagesNeedUpdate()
        #expect(card.superview != nil, "another window's request does not sync the card")
        #expect(windowA.childPageGeometry.pagesNeedUpdate() == 0, "a card reports no page change")
        #expect(card.superview == nil, "its window's request synced the card")

        // The page moves to window B; the chrome syncs there.
        page.isHidden = false
        windowB.contentView?.addSubview(page)
        overlays.sync()
        #expect(windowA.childPageGeometry.count == 0, "the card left window A's registry")
        #expect(windowB.childPageGeometry.count == 1)
        #expect(card.superview != nil)
        page.isHidden = true
        windowA.childPageGeometry.pagesNeedUpdate()
        #expect(card.superview != nil, "window A no longer reaches the card")
        windowB.childPageGeometry.pagesNeedUpdate()
        #expect(card.superview == nil, "window B's request syncs the card")

        overlays.remove(card)
        #expect(windowB.childPageGeometry.count == 0, "no card left: no registration")
    }
}
