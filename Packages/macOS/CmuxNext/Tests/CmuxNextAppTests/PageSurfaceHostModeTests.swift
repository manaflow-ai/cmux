import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextScreenshots
import CmuxNextSettings
import Testing

/// With the Chromium Host every page is a view of its window (`ChromiumHostPageView`),
/// so the child-window machinery of in-process Chromium is off: no child window but a content panel is
/// a page, the overlay planes stay in the window's view tree, no divider catcher panel is made, the
/// window's notices run no child order check, the layout takes no other window's scroll, and a
/// snapshot composites no child window under the page images. The in-process window (no
/// `PageSurfaceHosting`, or `.childWindows`) keeps every part of it.
@MainActor @Suite(.serialized) struct PageSurfaceHostModeTests {
    /// A main window that declares its page surface, as `ShellWindow` does from the browser backend.
    final class SurfaceWindow: NSWindow, PageSurfaceHosting {
        var pageSurface: PageSurface = .views
    }

    /// The main run loop's turn number the rig's layer reads (each turn is one event cycle).
    @MainActor final class TurnClock {
        var turn: UInt64 = 1
    }

    @MainActor private final class Rig {
        let center = NotificationCenter()
        let window: SurfaceWindow
        let layer: WindowOverlayLayer
        let clock: TurnClock
        private var children: [NSWindow] = []

        init(_ surface: PageSurface) {
            _ = NSApplication.shared
            let clock = TurnClock()
            self.clock = clock
            window = SurfaceWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                   backing: .buffered, defer: false)
            window.pageSurface = surface
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window.orderFrontRegardless()
            layer = WindowOverlayLayer(window: window, center: center, currentTurn: { clock.turn })
        }

        var host: WindowOverlayHost { WindowOverlayHost.host(for: window) }

        /// A plain borderless child over the window, as the in-process fork adds a page window.
        @discardableResult
        func addPlainChild() -> NSWindow {
            let child = NSWindow(contentRect: CGRect(x: 240, y: 240, width: 400, height: 300), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            return add(child)
        }

        /// A remote page's popup past the page's edge.
        @discardableResult
        func addContentPanel() -> NSWindow {
            let panel = ContentChildPanel()
            panel.setFrame(CGRect(x: 260, y: 260, width: 200, height: 120), display: false)
            return add(panel)
        }

        private func add(_ child: NSWindow) -> NSWindow {
            child.isReleasedWhenClosed = false
            window.addChildWindow(child, ordered: .above)
            children.append(child)
            layer.evaluate()
            return child
        }

        func close() {
            layer.teardown()
            for child in children {
                window.removeChildWindow(child)
                child.orderOut(nil)
            }
            window.orderOut(nil)
        }
    }

    @Test func theBackendPicksTheSurface() {
        #expect(BrowserBackend.inProcess.pageSurface == .childWindows)
        #expect(BrowserBackend.host.pageSurface == .views)
        #expect(PageSurface.of(NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)) == .childWindows,
                "a window that declares no surface keeps the in-process default")
    }

    @Test func aPlainChildIsNoPageInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        let child = rig.addPlainChild()

        #expect(!WindowOverlayLayer.isContent(child, of: rig.window))
        #expect(WindowOverlayLayer.contentChildWindows(of: rig.window).isEmpty)
        #expect(rig.layer.placement == .inWindow, "the overlay planes left the view tree with no page window")
        #expect(!rig.layer.pageWindowsTakeMouse)
        #expect(rig.layer.catchers == nil)
        #expect(!rig.window.isPageChild(child), "a snapshot would composite it under the page images")
    }

    @Test func theSamePlainChildIsAPageInProcess() {
        let rig = Rig(.childWindows)
        defer { rig.close() }
        let child = rig.addPlainChild()

        #expect(WindowOverlayLayer.isContent(child, of: rig.window))
        #expect(rig.layer.placement == .overlayWindow)
        #expect(rig.layer.pageWindowsTakeMouse)
        #expect(rig.window.isPageChild(child))
    }

    /// A content panel is page content on either surface: the overlay panel stays above it, but in host
    /// mode nothing takes the mouse over the layout, so no catcher is made.
    @Test func aContentPanelInHostModeGetsTheOverlayAboveItAndNoCatcher() {
        let rig = Rig(.views)
        defer { rig.close() }
        let popup = rig.addContentPanel()

        #expect(rig.window.isPageChild(popup))
        #expect(rig.layer.placement == .overlayWindow)
        #expect(rig.host.isAbovePages)
        #expect(!rig.layer.pageWindowsTakeMouse)
        #expect(rig.layer.catchers == nil)
    }

    /// In host mode the window's own notices (show, key, full screen) check no child order: nothing
    /// re-adds a page window behind the app's back. In process the same notices check it once each.
    @Test func windowNoticesRunNoOrderCheckInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        rig.addContentPanel()
        #expect(rig.host.isPanelAttached)
        let checks = rig.host.orderChecks
        let reorders = rig.host.reorderCount

        for _ in 0..<100 {
            rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
            rig.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.window)
        }

        #expect(rig.host.orderChecks == checks, "a window notice re-checked the child order in host mode")
        #expect(rig.host.reorderCount == reorders)
    }

    @Test func windowNoticesStillCheckTheOrderInProcess() {
        let rig = Rig(.childWindows)
        defer { rig.close() }
        rig.addPlainChild()
        let checks = rig.host.orderChecks

        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)

        #expect(rig.host.orderChecks == checks + 1)
    }

    /// The overlay host panel never re-adds itself over a plain child in host mode: that child is the
    /// app's, not a page the fork ordered above the overlays.
    @Test func aPlainChildAboveThePanelCausesNoReorderInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        rig.addContentPanel()
        let reorders = rig.host.reorderCount
        rig.addPlainChild()

        rig.host.reassertOrder()

        #expect(rig.host.reorderCount == reorders)
        #expect(WindowOverlayHost.frontPageWindow(at: CGPoint(x: 500, y: 400), in: rig.window) == nil,
                "a click the panel passes on went to a non-page child")
    }

    @Test func dividerCatchersShowNoPanelInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        let catchers = DividerMouseCatchers(window: rig.window)
        let area = LayoutMouseArea(id: "d", rect: CGRect(x: 396, y: 0, width: 8, height: 500), resizesColumns: true)

        catchers.update([area], active: true)

        #expect(catchers.shownCount == 0)
        #expect(catchers.panelUpdates == 0)
        #expect(!(rig.window.childWindows ?? []).contains { $0 is DividerMousePanel })
    }

    @Test func dividerCatchersStillShowInProcess() {
        let rig = Rig(.childWindows)
        defer { rig.close() }
        let catchers = DividerMouseCatchers(window: rig.window)
        let area = LayoutMouseArea(id: "d", rect: CGRect(x: 396, y: 0, width: 8, height: 500), resizesColumns: true)

        catchers.update([area], active: true)
        defer { catchers.update([], active: false) }

        #expect(catchers.shownCount == 1)
    }

    /// The layout routes only its own window's scrolls in host mode: a page scrolls in the window.
    @Test func theLayoutTakesNoChildWindowScrollInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        let child = rig.addPlainChild()

        #expect(LayoutRootView.scrollOrigin(of: child, at: CGPoint(x: 10, y: 10), in: rig.window) == nil)
        #expect(LayoutRootView.scrollOrigin(of: rig.window, at: CGPoint(x: 10, y: 10), in: rig.window)?.isPageWindow == false)
    }

    @Test func theLayoutStillTakesAPageWindowScrollInProcess() {
        let rig = Rig(.childWindows)
        defer { rig.close() }
        let child = rig.addPlainChild()

        #expect(LayoutRootView.scrollOrigin(of: child, at: CGPoint(x: 10, y: 10), in: rig.window)?.isPageWindow == true)
    }

    @Test func theChildWindowPolicyAllowsOnlyContentPanelsAsPagesInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        let plain = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)

        #expect(!ChildWindowPolicy.allows(plain, parent: rig.window), "a plain child is no page in host mode")
        #expect(ChildWindowPolicy.allows(ContentChildPanel(), parent: rig.window))
        #expect(ChildWindowPolicy.allows(plain, parent: NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)))
    }

    /// A page popup closes with `removeChildWindow` and `orderOut` only (NativePopupHost,
    /// RemoteBrowserSurfaces). In host mode no other window's notice is watched, so the window's
    /// `removeChildWindow` puts the planes back in the view tree and detaches the overlay panel.
    @Test func aContentPanelThatLeavesPutsThePlanesBackInHostMode() {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.pageSurface = .views
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.orderFrontRegardless()
        let popup = ContentChildPanel()
        popup.setFrame(CGRect(x: 260, y: 260, width: 200, height: 120), display: false)
        defer {
            window.overlayLayer.teardown()
            popup.orderOut(nil)
            window.orderOut(nil)
        }
        window.addChildWindow(popup, ordered: .above)
        #expect(window.overlayLayer.placement == .overlayWindow)
        #expect(WindowOverlayHost.host(for: window).isPanelAttached)

        window.removeChildWindow(popup)
        popup.orderOut(nil)

        #expect(window.overlayLayer.placement == .inWindow, "the closed popup kept the planes in the overlay panel")
        #expect(!WindowOverlayHost.host(for: window).isPanelAttached)
        #expect(WindowOverlayLayer.contentChildWindows(of: window).isEmpty)
    }

    /// `debug.overlay` `reorders_per_event` (the task's acceptance): in host mode no window notice
    /// re-adds the overlay panel over a page across event cycles, so it stays 0.
    @Test func reordersPerEventStaysZeroInHostMode() {
        let rig = Rig(.views)
        defer { rig.close() }
        rig.addContentPanel()
        rig.layer.resetOverlayStats()

        for _ in 0..<100 {
            rig.clock.turn += 1
            rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
            rig.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.window)
            rig.center.post(name: NSWindow.didMoveNotification, object: rig.window)
        }

        #expect(rig.layer.eventCyclesSinceReset == 100)
        #expect(rig.layer.reordersPerEvent == 0)
        let report = DebugLayers.overlay(rig.layer)
        #expect(report["reorders_per_event"]?.doubleValue == 0)
        #expect(report["event_cycles"]?.doubleValue == 100)
        #expect(report["page_surface"]?.stringValue == "views")
    }

    /// The control: in process a page window the fork adds above the overlay panel is a reorder, and
    /// `reorders_per_event` shows it.
    @Test func reordersPerEventCountsAPageReAddInProcess() {
        let rig = Rig(.childWindows)
        defer { rig.close() }
        rig.addPlainChild()
        rig.layer.resetOverlayStats()
        rig.clock.turn += 10

        rig.addPlainChild()

        #expect(rig.layer.reordersSinceReset == 1)
        #expect(rig.layer.reordersPerEvent == 0.1)
    }

    /// In host mode the focus ring draws in the window's view tree, under the page image a snapshot paints
    /// over the page's rect: the ring goes back over the page image there. A plane over the whole window
    /// (the inactive dim) is painted again only inside the page rect: outside it the base has it already.
    @Test func aRingOverAHostPageStaysAboveThePageImageInASnapshot() throws {
        let rig = Rig(.views)
        defer { rig.close() }
        let content = try #require(rig.window.contentView)
        let dim = NSView(frame: content.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        let ring = NSView(frame: CGRect(x: 100, y: 100, width: 40, height: 40))
        ring.wantsLayer = true
        ring.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        content.addSubview(dim)
        content.addSubview(ring)
        let size = CGSize(width: 800, height: 500)
        let base = try #require(ScreenshotPrivacyMaskTests.image(width: 800, height: 500, white: true))
        let pageImage = try #require(ScreenshotPrivacyMaskTests.image(width: 300, height: 300, white: false))
        let pages: [WindowImageLayer] = [.page(pageImage, CGRect(x: 50, y: 50, width: 300, height: 300))]

        let planes = try #require(WindowImageLayer.views([dim, ring], overPagesOf: pages, windowSize: size, scale: 1))
        let image = try #require(WindowImageLayer.composite(base: base, windowSize: size, layers: pages + [planes]))

        let pixels = try #require(ScreenshotPrivacyMaskTests.rgba(image))
        // Bitmap rows run top-down; window y counts from the bottom.
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = ((image.height - 1 - y) * image.width + x) * 4
            return Array(pixels[offset..<offset + 4])
        }
        #expect(pixel(120, 120) == [255, 0, 0, 255], "the page image covered the focus ring")
        #expect((120...135).contains(pixel(300, 300)[0]), "the dim is missing over the page")
        #expect(pixel(700, 450) == [255, 255, 255, 255], "the dim was painted twice outside the page")
        #expect(WindowImageLayer.views([dim, ring], overPagesOf: [], windowSize: size, scale: 1) == nil, "no page: nothing to repaint")
    }
}
