import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import ObjectiveC
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

    /// `CefNSWindow`, a Chromium page window's class: the app has it from the Chromium framework, a test process makes a
    /// stand-in of the same name.
    private static let pageWindowClass: NSWindow.Type = {
        if let existing = objc_lookUpClass("CefNSWindow") as? NSWindow.Type { return existing }
        let made: AnyClass = objc_allocateClassPair(NSWindow.self, "CefNSWindow", 0)!
        objc_registerClassPair(made)
        return made as! NSWindow.Type
    }()

    /// A page window the way the fork adds one: a borderless `CefNSWindow` over the pane, a child of the cmux window.
    private func pageWindow(_ frame: CGRect = CGRect(x: 400, y: 260, width: 300, height: 300),
                            type: NSWindow.Type? = nil) -> NSWindow {
        let page = (type ?? Self.pageWindowClass).init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    /// A window that is a child of the cmux window but no page: AppKit's text input or cursor accessory
    /// (`TUINSWindow`), or its lightweight UI host (`NSCampoLightweightUIHostWindow`, 0x0 at alpha 0).
    private final class SystemHelperWindowStandIn: NSWindow {}

    /// The window must stay in-window with `child` shown as a child of it, and count and name nothing.
    private func expectStaysInWindow(_ child: NSWindow, _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        inTree {
            let window = window()
            defer { window.close() }
            let host = WindowOverlayHost.host(for: window)
            window.overlayLayer.evaluate()
            let before = InTreeRetiredGuards.shared.dividerCatchers
            window.addChildWindow(child, ordered: .above)
            defer { window.removeChildWindow(child); child.close() }
            child.orderFront(nil)
            window.overlayLayer.evaluate()
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .inWindow, what, sourceLocation: sourceLocation)
            #expect(host.usesWindowBackend, what, sourceLocation: sourceLocation)
            #expect(InTreeRetiredGuards.shared.dividerCatchers == before, what, sourceLocation: sourceLocation)
            #expect(window.overlayLayer.retiredPageWindowSightings.isEmpty, what, sourceLocation: sourceLocation)
        }
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
            #expect(window.overlayLayer.retiredPageWindowSightings.last?.contains("#\(page.windowNumber)") == true)

            window.removeChildWindow(page)
            page.orderOut(nil)
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .inWindow, "the page window left: in-window again")
            #expect(host.usesWindowBackend)
        }
    }

    /// The user's session on 34f21f2f (New Tab, a Google sign-in, Settings, Debug Settings): `debug.layers` read
    /// `placement: overlayWindow` with every page in the pane, because AppKit's helper windows and Chromium's headless
    /// or parked page windows counted as page windows on screen. Only a real page window that shows counts.
    @Test func aTextInputAccessoryWindowIsNoPageWindow() {
        let helper = pageWindow(CGRect(x: 420, y: 300, width: 64, height: 64), type: SystemHelperWindowStandIn.self)
        expectStaysInWindow(helper, "a TUINSWindow-like helper over the pane")
    }

    @Test func aZeroSizeTransparentHelperWindowIsNoPageWindow() {
        let helper = pageWindow(CGRect(x: 400, y: 260, width: 0, height: 0), type: SystemHelperWindowStandIn.self)
        helper.alphaValue = 0
        expectStaysInWindow(helper, "a 0x0 alpha 0 NSCampoLightweightUIHostWindow-like helper")
    }

    @Test func aHeadlessPageWindowAtAlphaZeroIsNotOnScreen() {
        let page = pageWindow(CGRect(x: 220, y: 220, width: 869 - 100, height: 642 - 200))
        page.alphaValue = 0
        expectStaysInWindow(page, "a CefNSWindow at alpha 0 over the window")
    }

    @Test func aParkedPageWindowIsNotOnScreen() {
        let page = pageWindow(CGRect(x: -98765, y: -99520, width: 869, height: 642))
        expectStaysInWindow(page, "a CefNSWindow parked far off screen")
    }

    /// A page window that shows and then hides (alpha 0, parked, or ordered out) puts the window back in-window: the
    /// placement never sticks on the panel.
    @Test func aPageWindowThatShowsThenHidesLeavesThePlacementInWindow() {
        inTree {
            let window = window()
            defer { window.close() }
            let host = WindowOverlayHost.host(for: window)
            let page = pageWindow()
            window.addChildWindow(page, ordered: .above)
            defer { window.removeChildWindow(page); page.close() }
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .overlayWindow, "shown over the pane: the panel serves it")

            page.alphaValue = 0
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .inWindow, "alpha 0: in-window again")
            #expect(host.usesWindowBackend)

            page.alphaValue = 1
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .overlayWindow, "shown again")

            page.setFrameOrigin(CGPoint(x: -98765, y: -99520))
            window.overlayLayer.evaluate()
            #expect(window.overlayLayer.placement == .inWindow, "parked: in-window again")
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
        #expect(window.overlayLayer.retiredPageWindowSightings.isEmpty)
    }
}
