import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// A Chromium page window that the fork adds as a child window never
/// covers the app overlay (focus ring, dim, drop highlight), not even for
/// one frame: the overlay panel is above it when `addChildWindow` returns,
/// before the window server composites the page. Before, the order was
/// fixed on the page's later notifications, so a new tab (Cmd-Shift-L)
/// showed one frame of page over the focus ring.
@MainActor
struct OverlayPageOrderTests {
    /// Off-screen so the test never shows a window on the user's display,
    /// but ordered in: child windows are ordered only under a visible parent.
    private func makeShell() -> ShellWindow {
        let shell = ShellWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        shell.orderFrontRegardless()
        return shell
    }

    private func makePage() -> NSWindow {
        let page = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 500), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    @Test func aPageAddedAboveTheOverlayIsBelowItWhenTheCallReturns() {
        let shell = makeShell()
        defer {
            shell.overlayLayer.teardown()
            shell.orderOut(nil)
        }
        let first = makePage()
        shell.addChildWindow(first, ordered: .above)
        #expect(shell.overlayLayer.placement == .overlayWindow, "the first page lifts the overlay at once")
        #expect(shell.overlayLayer.isOverlayAboveContent)

        // The fork adds (or re-adds) a second page above everything.
        let second = makePage()
        shell.addChildWindow(second, ordered: .above)
        #expect(shell.overlayLayer.isOverlayAboveContent, "no frame with a page above the overlay")
        shell.addChildWindow(first, ordered: .above)
        #expect(shell.overlayLayer.isOverlayAboveContent, "a re-added page goes below the overlay too")

        for page in [first, second] {
            shell.removeChildWindow(page)
            page.orderOut(nil)
        }
    }
}

/// The sidebar is an occluder: Chromium pages get its rect as an occlusion
/// rect, so the fork masks the page there and routes the mouse to the window.
@MainActor
@Suite(.serialized) struct OverlaySidebarOccluderTests {
    @Test func pagesAreMaskedUnderTheSidebar() {
        let shell = ShellWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        shell.isReleasedWhenClosed = false
        defer {
            shell.overlayLayer.teardown()
            shell.close()
        }
        let sidebar = NSRect(x: 0, y: 0, width: 240, height: 600)
        WindowOverlayHost.host(for: shell).setOccluder(id: "sidebar", rect: sidebar)
        #expect(shell.browserOcclusionRectsInWindow.contains(sidebar))
        WindowOverlayHost.host(for: shell).setOccluder(id: "sidebar", rect: nil)
        #expect(!shell.browserOcclusionRectsInWindow.contains(sidebar))
    }
}
