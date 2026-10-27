import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// p06-scheduler-221: no per-event check puts the overlay host's panel back above a page window
/// the fork re-adds, so every window that shows pages does it from `addChildWindow`. The DevTools
/// window shows the DevTools page and can hold an overlay (a context menu over DevTools).
@MainActor @Suite(.serialized) struct CEFDevToolsWindowOverlayOrderTests {
    @Test func aPageAddedToTheDevToolsWindowGoesBelowItsOverlayPanel() {
        _ = NSApplication.shared
        let window = CEFDevToolsWindow(frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        window.orderFrontRegardless()
        let host = WindowOverlayHost.host(for: window)
        host.setPlanesWantPanel(true)
        let page = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 380), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        defer {
            window.removeChildWindow(page)
            page.orderOut(nil)
            host.setPlanesWantPanel(false)
            window.close()
        }
        #expect(host.isPanelAttached)

        window.addChildWindow(page, ordered: .above)

        #expect(page.parent === window)
        #expect(host.isAbovePages, "the DevTools page covers the window's overlays")
    }
}
