import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Leo's first-frame call (BACKLOG "Ideas"): a cold launch with a saved layout paints it in its first
/// frame and goes live with no flash. The launch window's pane holds its tab strip and content clear
/// until their data lands (`LaunchReveal`). A relaunch has that data before the window's first frame
/// (the saved tabs, an agent page's last image), so they must draw in that frame, not fade in from
/// clear after it. Data that lands after the first frame still fades in. A real pane in a window.
@MainActor @Suite(.serialized) struct LaunchFirstFrameRevealTests {
    final class LaunchWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reveal = LaunchReveal(deadline: .seconds(60))
        let pane: PaneContentView

        init() {
            window.isReleasedWhenClosed = false
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]), reveal: reveal)
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            pane.layoutSubtreeIfNeeded()
        }

        /// Whether `view` draws in the next frame as it will stay: fully opaque, with no fade running.
        func drawsAtOnce(_ view: NSView) -> Bool {
            view.alphaValue == 1 && view.layer?.animation(forKey: "opacity") == nil
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func tabsThatArriveBeforeTheFirstFrameDrawInIt() {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        // The saved tabs, before the window ever drew (PaneController's first strip sync).
        launch.reveal.markReady(.tabs)
        #expect(launch.drawsAtOnce(launch.pane.stripView), "the first frame drew the saved tabs clear, then faded them in")
        #expect(launch.pane.contentHost.alphaValue == 0, "the pane's content stays held until its own data lands")
    }

    @Test func contentThatArrivesBeforeTheFirstFrameDrawsInIt() {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        // An agent page's last image, shown as the window opens (PaneController.showSelected).
        launch.reveal.markReady(.pane)
        #expect(launch.drawsAtOnce(launch.pane.contentHost), "the first frame drew the pane clear, then faded it in")
    }

    /// A host with no screen commits no frame (the layer gets no presentation copy).
    @Test(.enabled("a window with no screen draws no frame") { await MainActor.run { !NSScreen.screens.isEmpty } },
          .enabled("animation speed is off on this host") { await MainActor.run { Motion.speed != .off } })
    func dataThatArrivesAfterTheFirstFrameFadesIn() throws {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        // The window's first frame, with the strip held clear in it.
        CATransaction.flush()
        try #require(launch.pane.stripView.layer?.presentation() != nil, "the window drew no frame")
        launch.reveal.markReady(.tabs)
        #expect(launch.pane.stripView.alphaValue == 1)
        #expect(launch.pane.stripView.layer?.animation(forKey: "opacity") != nil, "tabs that came after the first frame showed with no fade")
    }
}
