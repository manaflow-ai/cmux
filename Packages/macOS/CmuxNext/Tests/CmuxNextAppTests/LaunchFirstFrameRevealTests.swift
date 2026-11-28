import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo's first-frame call (BACKLOG "Ideas"): a cold launch with a saved layout paints it in its first
/// frame and goes live with no flash. The launch window's pane holds its tab strip and content clear
/// until their data lands (`LaunchReveal`). A relaunch has that data before the window's first frame
/// (the saved tabs, an agent page's last image), so they must draw in that frame, not fade in from
/// clear after it. Data that lands after the first frame still fades in. A real pane in a window.
@MainActor @Suite(.serialized, .closesItsWindows) struct LaunchFirstFrameRevealTests {
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
            // A test that ends with its frame still up (one whose page never painted) would leave
            // `LaunchImageHold.shared` counting it for the rest of the process: the pane's deinit
            // does not end the hold by design, so the next test to await it would take the 4 s
            // backstop instead of returning at once.
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
        launch.pane.showLaunchImage(Self.lastFrame(), limit: .milliseconds(40))
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
        launch.pane.showLaunchImage(Self.lastFrame(), limit: .milliseconds(40))
        launch.pane.launchImageMayClear = { true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(launch.pane.launchImageView == nil, "a frame over a page that had drawn stayed past its limit")
    }

    @Test func aPreviousPageCannotClearTheNextPagesFrame() throws {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.showLaunchImage(Self.lastFrame())
        let previous = try #require(launch.pane.launchImageView)
        launch.pane.showLaunchImage(Self.lastFrame())
        let current = try #require(launch.pane.launchImageView)
        launch.pane.clearLaunchImage(ifShowing: previous)
        #expect(launch.pane.launchImageView === current,
                "the previous tab's delayed reveal took back the next tab's frame")
        launch.pane.clearLaunchImage(ifShowing: current)
        #expect(launch.pane.launchImageView == nil)
    }

    @Test func resizingThePaneDropsTheOldSizeFrame() {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.showLaunchImage(Self.lastFrame())
        #expect(launch.pane.launchImageView != nil)
        launch.pane.setFrameSize(NSSize(width: 700, height: 600))
        launch.pane.layoutSubtreeIfNeeded()
        #expect(launch.pane.launchImageView == nil,
                "a launch snapshot from the old pane width remained visible after resize")
    }

    /// A chat whose header tools join the pane's tab row once its page reports them
    /// (`pane.tabRowTools`), as a restored chat's page does on its first render.
    final class RowChat: NSView, PaneTabRowSharing {
        var reported: CGFloat = 0 {
            didSet { onTabRowToolsChange?() }
        }
        var onTabRowToolsChange: (() -> Void)?
        var tabRowToolsWidth: CGFloat? { reported > 0 ? reported : nil }
        var tabRowToolsNeed: CGFloat? { reported > 0 ? reported : nil }
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {}
    }

    /// Leo 2026-10-24: "on the first load after a restart, I saw a black screen for the Chromium, the
    /// Agent pane area". The saved frame of a chat is the chat's own view at quit, which shares the
    /// tab row and so fills the whole pane. At launch the page has not reported its row tools yet, so
    /// the pane lays its content under the strip; once the page draws its header and reports them,
    /// the content grows back over the row to exactly the frame's size. That resize took the frame
    /// and showed the empty loading state (black in dark mode) until the chat was read, 0.5-1.6 s on
    /// the fleet's restore bench. A frame the pane grows to fit stays.
    @Test func aChatJoiningTheTabRowKeepsItsLastFrame() throws {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        let chat = RowChat()
        launch.pane.show(chat)
        launch.pane.layoutSubtreeIfNeeded()
        let underStrip = launch.pane.contentHost.bounds.size
        let full = launch.pane.bounds.size
        try #require(underStrip.height < full.height, "the test pane has no tab strip to share")
        var clearedCallbacks = 0
        // The saved frame came back a point short of the pane on the fleet (816x680 against 816x681).
        let frame = NSImage(size: NSSize(width: full.width, height: full.height - 1), flipped: false) { rect in
            NSColor.textBackgroundColor.setFill()
            rect.fill()
            return true
        }
        launch.pane.showLaunchImage(frame)
        launch.pane.onLaunchImageCleared = { clearedCallbacks += 1 }
        let shown = try #require(launch.pane.launchImageView)
        chat.reported = 120
        launch.pane.needsLayout = true
        launch.pane.layoutSubtreeIfNeeded()
        #expect(launch.pane.contentHost.bounds.size == full, "the chat's tools did not take the tab row")
        #expect(launch.pane.launchImageView === shown,
                "the pane dropped the chat's last frame when the chat joined the tab row, showing its empty loading state")
        #expect(clearedCallbacks == 0)
        // Any other size still drops it: those pixels are from another layout.
        launch.pane.setFrameSize(NSSize(width: 700, height: 600))
        launch.pane.layoutSubtreeIfNeeded()
        #expect(launch.pane.launchImageView == nil)
    }

    @Test(arguments: [false, true])
    func aPageThatLeavesThePaneTakesItsUnpaintedFrameWithIt(parks: Bool) {
        let launch = LaunchWindow()
        defer { launch.tearDown() }
        launch.pane.show(NSView())
        launch.pane.showLaunchImage(Self.lastFrame())
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
