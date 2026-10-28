import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// No per-event check puts the overlay host's panel back above a page window
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

    /// In host mode the DevTools page is a view of the panel (the hosted page), so
    /// its overlay host checks no child order on the panel's notices; in process each notice checks it.
    @Test(arguments: [PageSurface.views, .childWindows])
    func theDevToolsWindowChecksTheOrderOnItsNoticesOnlyInProcess(_ surface: PageSurface) {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let window = CEFDevToolsWindow(frame: CGRect(x: 100, y: 100, width: 600, height: 400), pageSurface: surface)
        _ = WindowEvents.of(window, center: center)
        window.orderFrontRegardless()
        let host = WindowOverlayHost.host(for: window)
        host.setPlanesWantPanel(true)
        defer {
            host.setPlanesWantPanel(false)
            window.close()
        }
        #expect(PageSurface.of(window) == surface)
        #expect(host.isPanelAttached)
        let checks = host.orderChecks

        for _ in 0..<10 {
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }

        #expect(host.orderChecks == checks + (surface == .views ? 0 : 20), "a DevTools window notice checked the child order")
    }
}
