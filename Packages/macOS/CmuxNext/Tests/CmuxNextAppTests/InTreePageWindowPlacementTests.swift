import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// With in-tree pages on, no page should be a window, but one can still show: a page the fork refused twice goes back
/// to its own window (`CEFInTreeHosting.fellBack`). The window's overlay layer must serve it as with the mode off (the
/// planes and the presented overlays in the panel above it, the divider catchers on), not force the in-window placement
/// under it; and it counts the window once (`InTreeRetiredGuards.dividerCatchers`) and names it in `debug.layers`.
@MainActor @Suite(.serialized, .closesItsWindows) struct InTreePageWindowPlacementTests {
    private func window() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        return window
    }

    /// A page window the way the fork adds one: a plain borderless window over the pane, a child of the cmux window.
    private func pageWindow() -> NSWindow {
        let page = NSWindow(contentRect: CGRect(x: 400, y: 260, width: 300, height: 300), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    private func inTree<T>(_ body: () throws -> T) rethrows -> T {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: false) }
        return try body()
    }

    @Test func aPageWindowOnScreenInTreeIsServedLikeWithTheModeOff() {
        inTree {
            let window = window()
            defer { window.close() }
            let host = WindowOverlayHost.host(for: window)
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .inWindow, "no page window: in-window")
            #expect(host.usesWindowBackend, "no page window: the overlays are views on the window")
            let before = InTreeRetiredGuards.shared.dividerCatchers

            let page = pageWindow()
            window.addChildWindow(page, ordered: .above)
            defer { page.close() }
            window.overlayLayer.evaluate()
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .overlayWindow, "a page window on screen: the panel serves it")
            #expect(!host.usesWindowBackend, "the overlays go back to the panel above the page window")
            #expect(InTreeRetiredGuards.shared.dividerCatchers == before + 1, "one window counted once, not per evaluate")

            window.removeChildWindow(page)
            page.orderOut(nil)
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .inWindow, "the page window left: in-window again")
            #expect(host.usesWindowBackend)
        }
    }

    /// Nothing changes with the mode off: a page window puts the window in page mode and nothing is counted.
    @Test func withTheModeOffNothingIsCounted() {
        InTreePages.shared.setForTesting(requested: false)
        let window = window()
        defer { window.close() }
        let before = InTreeRetiredGuards.shared.dividerCatchers
        let page = pageWindow()
        window.addChildWindow(page, ordered: .above)
        defer { window.removeChildWindow(page); page.close() }
        window.overlayLayer.evaluate()
        #expect(window.overlayLayer.placement == .overlayWindow)
        #expect(InTreeRetiredGuards.shared.dividerCatchers == before)
    }
}
