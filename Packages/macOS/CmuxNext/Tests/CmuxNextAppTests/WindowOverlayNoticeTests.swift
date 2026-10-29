import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserCore
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// The overlay layer and its host observed `NSWindow.didUpdateNotification`, so every
/// event of the window (each key typed) re-ran the layer's after-pass work, its placement check and the
/// host's child order check, with no overlay change. They now act on the specific notices (the window's
/// own through its `WindowEvents`, a page window's appear, hide, move or key), and a layout depth counts
/// only in the turn that began its pass. The window's notices come from the test's own center: the layer
/// makes the window's `WindowEvents` on it, and the host shares it.
@MainActor @Suite(.serialized) struct WindowOverlayNoticeTests {
    /// The main run loop's turn number (`MainTurnMeter.turnNumber`), moved by the test.
    @MainActor private final class Turns {
        var number: UInt64 = 1

        func next() { number += 1 }
    }

    @MainActor private final class Count {
        var value = 0
    }

    @MainActor private final class Rig {
        let center: NotificationCenter
        let turns: Turns
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
            let turns = Turns()
            self.window = window
            self.page = page
            self.center = center
            self.turns = turns
            layer = WindowOverlayLayer(window: window, center: center, currentTurn: { turns.number })
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

        // AppKit posts didUpdate once per event of the window: the stand-in for 100 keys, on the center the
        // layer and the host observe (the window's `WindowEvents` and the page observers are on it).
        for _ in 0..<100 {
            rig.center.post(name: NSWindow.didUpdateNotification, object: rig.window)
            rig.center.post(name: NSWindow.didUpdateNotification, object: rig.page)
        }

        #expect(!WindowEvents.of(rig.window).isObserving(NSWindow.didUpdateNotification))
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

    @Test func aStaleLayoutDepthFromAnEarlierTurnCountsAsNoPass() {
        let rig = Rig()
        defer { rig.close() }
        let layer = rig.layer

        // A normal pass, nested once.
        layer.windowWillLayout()
        layer.windowWillLayout()
        layer.windowDidLayout()
        #expect(layer.layoutDepth == 1)
        layer.windowDidLayout()
        #expect(layer.layoutDepth == 0)

        // An exception AppKit caught skipped the pass's end: in its own turn the pass still counts.
        layer.windowWillLayout()
        #expect(layer.layoutDepth == 1)
        rig.turns.next()
        #expect(layer.layoutDepth == 0, "a depth from an earlier turn holds this turn's deferred work")

        // The next turn's pass is the outermost one (ShellWindow runs its after-pass work at depth 1).
        layer.windowWillLayout()
        #expect(layer.layoutDepth == 1)
        layer.windowDidLayout()
        #expect(layer.layoutDepth == 0)
    }

    /// The window's after-pass blocks (`afterLayoutPass`) queued in the pass an exception cut short run
    /// at the end of the next turn's first pass: it is the outermost one, not a pass nested at depth 2.
    @Test func theFirstPassAfterAStaleDepthRunsTheWindowsAfterPassWork() {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let meter = MainTurnMeter()
        window.turnMeter = meter
        defer {
            window.overlayLayer.teardown()
            window.orderOut(nil)
        }

        meter.loopWoke()
        // The pass began and an exception AppKit caught skipped its end.
        window.overlayLayer.windowWillLayout()
        var ran = 0
        window.afterLayoutPass { ran += 1 }
        #expect(ran == 0, "a block asked for inside the pass ran inside it")
        meter.loopWillWait()
        meter.loopDidRender()

        meter.loopWoke()
        #expect(!window.isInLayoutPass, "the stale pass still counts in the next turn")
        window.layoutIfNeeded()
        #expect(ran == 1, "the next turn's first pass skipped the after-pass work")
        #expect(window.overlayLayer.layoutDepth == 0)
        withExtendedLifetime(meter) {}
    }

    /// A move or an occlusion change schedules no layout pass: the page update it owes after "the pass
    /// the change schedules" never waits for an unrelated pass in a later turn (a key or a tab switch).
    @Test func aMoveOwesNoPageUpdateToALaterTurnsPass() {
        let rig = Rig()
        defer { rig.close() }
        rig.showPage()
        // The layer asks the window's pages through its page registry (`CEFHostView` registers there).
        let posts = Count()
        let watch = ChildPageGeometryRegistry.of(rig.window).register { _ in
            posts.value += 1
            return false
        }

        rig.center.post(name: NSWindow.didMoveNotification, object: rig.window)
        #expect(posts.value == 1, "the pages follow the move at once")

        // A later turn's pass (typing): no page update for the move.
        rig.turns.next()
        rig.layer.windowWillLayout()
        rig.layer.windowDidLayout()
        #expect(posts.value == 1, "the move's follow-up page update ran in an unrelated pass")

        // A resize in this turn: its pass, in the same turn, updates the pages once more.
        rig.center.post(name: NSWindow.didResizeNotification, object: rig.window)
        #expect(posts.value == 2)
        rig.layer.windowWillLayout()
        rig.layer.windowDidLayout()
        #expect(posts.value == 3, "the pass the resize scheduled did not update the pages again")
        withExtendedLifetime(watch) {}
    }
}
