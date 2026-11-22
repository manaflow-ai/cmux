import AppKit
import CmuxNextDesign
import CmuxNextTabs
import Testing
@testable import CmuxNextApp

/// The New Tab page over the pane's previous content, blurred and dimmed (Lawrence's reference,
/// 2026-10-05): the previous content stays in place under a frost, the page draws over both, and
/// anything else shown in the pane takes the backdrop away.
@MainActor @Suite struct NewTabBackdropTests {
    func pane() -> (PaneContentView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let pane = PaneContentView(stripModel: TabStripModel())
        pane.frame = window.contentView!.bounds
        window.contentView!.addSubview(pane)
        pane.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    @Test func thePageShowsOverThePreviousContentUnderAFrostUntilAnotherContentShows() throws {
        let (pane, window) = pane()
        defer { window.close() }
        // A translucent window shows its own backdrop through the page: no second one.
        let opaque = WindowBackdrop(pane.themeTokens).panesPaintBackground
        let terminal = NSView()
        pane.show(terminal)
        let page = NSView()
        pane.show(page, overBackdrop: true)
        #expect(page.superview === pane.contentHost)
        #expect(pane.contentHost.subviews.last === page, "the page is on top")
        if opaque {
            let frost = try #require(pane.frost)
            #expect(pane.contentHost.subviews == [terminal, frost, page])
            #expect(frost.frame == pane.contentHost.bounds)
            #expect(frost.hitTest(NSPoint(x: 10, y: 10)) == nil, "never hit")
        } else {
            #expect(pane.contentHost.subviews == [page])
        }

        // A second page over the first keeps the content before the first one as the backdrop.
        let second = NSView()
        pane.show(second, overBackdrop: true)
        #expect(page.superview == nil)
        if opaque { #expect(pane.contentHost.subviews == [terminal, pane.frost!, second]) }

        // The previous tab again: it is in place, nothing over it.
        pane.show(terminal)
        #expect(pane.contentHost.subviews == [terminal])
        #expect(pane.frost == nil && pane.underlay == nil)
    }

    @Test func thePageBecomingAChatOrLeavingTheWindowDropsTheBackdrop() {
        let (pane, window) = pane()
        defer { window.close() }
        let terminal = NSView()
        pane.show(terminal)
        let page = NSView()
        pane.show(page, overBackdrop: true)
        pane.dropBackdrop(keeping: nil)
        #expect(pane.contentHost.subviews == [page])
        pane.show(terminal)
        pane.show(page, overBackdrop: true)
        pane.detachContent()
        #expect(pane.contentHost.subviews.isEmpty)
    }
}
