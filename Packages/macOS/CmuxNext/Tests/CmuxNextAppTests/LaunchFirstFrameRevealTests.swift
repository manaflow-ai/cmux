import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLaunch
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
        /// The window's own launch image hold (no startup scheduler): each test starts with none shown.
        let hold = LaunchImageHold()
        let pane: PaneContentView

        init() {
            window.isReleasedWhenClosed = false
            pane = PaneContentView.testing(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]), reveal: reveal)
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
            // A test that ends with its frame still up (one whose page never painted) would leave its
            // hold counting it: the pane's deinit does not end the hold's share by design.
            pane.clearLaunchImage()
            window.orderOut(nil)
            window.close()
        }
    }

    /// A stand-in for an agent page's last frame (`AgentPaneLaunchImages`).
    private static func lastFrame() -> NSImage {
        NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.textBackgroundColor.setFill()
            rect.fill()
            return true
        }
    }

    /// Leo 2026-10-22, on a chat at launch: it "flickers the initial thing/paints and renders it...
    /// and then it just goes to black screen for a while". The pane drew the chat's last frame, took
    /// it back at `paneLaunchImageLimit`, and showed its empty loading state until the page reported
    /// a first frame — which waits on acpmux reading the chat, several seconds on a busy daemon. The
    /// frame stays while the page it stands in for is still coming; the pane's own give-up on a page
    /// that never reports is what ends it then (`AgentPaneLoadingView`).
    @Test func theLastFrameWaitsForThePageItStandsInFor() async throws {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.showLaunchImage(Self.lastFrame(), hold: launch.hold, limit: .milliseconds(40))
        launch.pane.launchImageMayClear = { false }
        try await Task.sleep(for: .milliseconds(300))
        #expect(launch.pane.launchImageView != nil,
                "the pane took back the chat's last frame while its page was still coming, leaving it empty")
    }

    /// A frame held over a page that has drawn is the other half: its limit still takes it, so a
    /// cover that outlived its purpose never stays (`coverMove`).
    @Test func theLastFrameGoesAtItsLimitOnceThePageDrew() async throws {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.showLaunchImage(Self.lastFrame(), hold: launch.hold, limit: .milliseconds(40))
        launch.pane.launchImageMayClear = { true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(launch.pane.launchImageView == nil, "a frame over a page that had drawn stayed past its limit")
    }

    @Test func aPreviousPageCannotClearTheNextPagesFrame() throws {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.showLaunchImage(Self.lastFrame(), hold: launch.hold)
        let previous = try #require(launch.pane.launchImageView)
        launch.pane.showLaunchImage(Self.lastFrame(), hold: launch.hold)
        let current = try #require(launch.pane.launchImageView)
        launch.pane.clearLaunchImage(ifShowing: previous)
        #expect(launch.pane.launchImageView === current,
                "the previous tab's delayed reveal took back the next tab's frame")
        launch.pane.clearLaunchImage(ifShowing: current)
        #expect(launch.pane.launchImageView == nil)
    }

    @Test(arguments: [false, true])
    func aPageThatLeavesThePaneTakesItsUnpaintedFrameWithIt(parks: Bool) {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.show(NSView())
        launch.pane.showLaunchImage(Self.lastFrame(), hold: launch.hold)
        launch.pane.launchImageMayClear = { false }
        launch.pane.detachContent(parks: parks)
        #expect(launch.pane.launchImageView == nil,
                "a closed or displaced page left its last frame covering the empty pane")
        #expect(launch.pane.launchImageMayClear == nil)
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
