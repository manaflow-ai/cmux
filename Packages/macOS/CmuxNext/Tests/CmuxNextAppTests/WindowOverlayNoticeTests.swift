import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import Testing

/// p06-scheduler-221: the overlay layer and its host observed `NSWindow.didUpdateNotification`, so every
/// event of the window (each key typed) re-ran the layer's after-pass work, its placement check and the
/// host's child order check, with no overlay change. They now act on the specific notices (the window's
/// own through its `WindowEvents`, a page window's appear, hide, move or key), and a layout depth left by
/// an exception clears once at the end of the turn that began the pass. The window's notices come from
/// the test's own center: the layer makes the window's `WindowEvents` on it, and the host shares it.
@MainActor @Suite(.serialized) struct WindowOverlayNoticeTests {
    @MainActor private final class TurnEnds {
        var pending: [@MainActor () -> Void] = []

        func run() {
            let work = pending
            pending.removeAll()
            for body in work { body() }
        }
    }

    @MainActor private final class Rig {
        let center: NotificationCenter
        let turnEnds: TurnEnds
        let window: NSWindow
        let page: NSWindow
        let layer: WindowOverlayLayer

        init() {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window.orderFrontRegardless()
            let page = NSWindow(contentRect: CGRect(x: 240, y: 240, width: 400, height: 300), styleMask: [.borderless],
                                backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            let center = NotificationCenter()
            let turnEnds = TurnEnds()
            self.window = window
            self.page = page
            self.center = center
            self.turnEnds = turnEnds
            layer = WindowOverlayLayer(window: window, center: center, atTurnEnd: { turnEnds.pending.append($0) })
        }

        /// The Chromium fork adds a page as a child window (`ShellWindow.addChildWindow` then evaluates).
        func showPage() {
            window.addChildWindow(page, ordered: .above)
            layer.evaluate()
        }

        var host: WindowOverlayHost { WindowOverlayHost.host(for: window) }

        func close() {
            layer.teardown()
            window.removeChildWindow(page)
            page.orderOut(nil)
            window.orderOut(nil)
        }
    }

    @Test func aHundredWindowUpdatesRunNoOverlayCheck() {
        let rig = Rig()
        defer { rig.close() }
        rig.showPage()
        #expect(rig.layer.placement == .overlayWindow, "a page window puts the window in page mode")
        let evaluations = rig.layer.evaluations
        let orderChecks = rig.host.orderChecks
        let reorders = rig.layer.reorderCount

        // AppKit posts didUpdate once per event of the window: the stand-in for 100 keys.
        for _ in 0..<100 { rig.window.update() }

        #expect(rig.layer.evaluations == evaluations, "a window update re-checked the overlay placement")
        #expect(rig.host.orderChecks == orderChecks, "a window update re-checked the child order")
        #expect(rig.layer.reorderCount == reorders)
    }

    @Test func theWindowShowingAgainChecksPlacementAndOrderOnce() {
        let rig = Rig()
        defer { rig.close() }
        rig.showPage()
        let evaluations = rig.layer.evaluations
        let orderChecks = rig.host.orderChecks

        rig.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.window)

        #expect(rig.layer.evaluations == evaluations + 1)
        #expect(rig.host.orderChecks == orderChecks + 1)
    }

    @Test func aPageThatLeftTheChildListTakesTheWindowOutOfPageMode() {
        let rig = Rig()
        defer { rig.close() }
        rig.showPage()
        #expect(rig.layer.placement == .overlayWindow)

        // Ordered out, the page is no longer a child when its occlusion notice comes.
        rig.window.removeChildWindow(rig.page)
        rig.page.orderOut(nil)
        rig.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.page)

        #expect(rig.layer.placement == .inWindow, "a hidden page left the overlay in its panel")
    }

    @Test func aStaleLayoutDepthClearsAtTheEndOfItsTurn() {
        let rig = Rig()
        defer { rig.close() }
        let layer = rig.layer

        // A normal pass, nested once: one check, and it finds nothing to clear.
        layer.windowWillLayout()
        layer.windowWillLayout()
        layer.windowDidLayout()
        layer.windowDidLayout()
        #expect(rig.turnEnds.pending.count == 1, "one check per turn that began a pass")
        rig.turnEnds.run()
        #expect(layer.layoutDepth == 0)

        // An exception AppKit caught skipped the pass's end: the turn's end clears the depth.
        layer.windowWillLayout()
        #expect(layer.layoutDepth == 1)
        rig.turnEnds.run()
        #expect(layer.layoutDepth == 0, "a stale depth held the deferred work")
        #expect(rig.turnEnds.pending.isEmpty)
    }
}
