import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDesign
import CmuxNextDaemon
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// cx-sqj3h (Leo 2026-10-13): during a window live resize the content must follow the edge every
/// frame. Nothing animates toward a size the next frame replaces: a layout change that lands
/// mid-drag snaps, a tab strip that starts overflowing fades its edge at once, and a terminal's
/// new grid goes to its owner the next frame instead of after the drag stops. After the resize
/// ends, motion is as before.
///
/// A window enters a live resize through AppKit's `willStartLiveResize` notification, which a
/// test posts for its own window (AppKit's resize tracking needs a real pointer). Every test is
/// synchronous, so the process-wide motion state cannot leak into another test.
@MainActor @Suite(.serialized, .closesItsWindows) struct LiveResizeTrackingTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: CmuxNextLayout.PaneID) -> NSView { NSView() }
    }

    static func window(width: CGFloat, height: CGFloat) -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    /// `body` runs inside a live resize, as between AppKit's start and end notifications.
    static func liveResize(_ body: () -> Void) {
        Motion.liveResizeOverride = true
        defer { Motion.liveResizeOverride = nil }
        body()
    }

    static func split(_ ratio: Double) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .splits(.split("v", axis: .horizontal, ratio: ratio, a: .leaf("p1"), b: .leaf("p2"))))]
    }

    @Test func aLayoutChangeThatLandsMidDragSnapsWithTheWindowAndSpringsAgainAfter() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        // Pane layout springs only with `ui.paneAnimations` on (off by default).
        let paneAnimations = DesignSettings.shared.paneAnimations
        DesignSettings.shared.paneAnimations = true
        defer { DesignSettings.shared.paneAnimations = paneAnimations }
        try #require(Motion.panes.animatesMovement, "animation speed is off on this host")
        let provider = Panes()
        let model = LayoutModel(screens: Self.split(0.5), activeScreenID: "s", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = Self.window(width: 1000, height: 700)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        let screen = try #require(root.screenViews["s"])
        func settled(_ pane: CmuxNextLayout.PaneID) -> Bool {
            guard let shown = screen.displayedFrame(of: pane), let target = screen.geometry.panes[pane] else { return false }
            return abs(shown.minX - target.minX) < 0.5 && abs(shown.width - target.width) < 0.5
        }

        Self.liveResize {
            // One frame of the drag each: the window grows, then another client's divider move lands.
            for (step, ratio) in [0.45, 0.4, 0.35, 0.3].enumerated() {
                window.setContentSize(NSSize(width: 1000 + 40 * CGFloat(step + 1), height: 700))
                root.layoutSubtreeIfNeeded()
                // Between this frame's layout and the next one's.
                model.apply(screens: Self.split(ratio))
                root.syncWithModel()
                // With no frame stepped: every pane is where this frame's layout puts it.
                #expect(settled("p1") && settled("p2"), "frame \(step + 1): a pane springs toward the layout mid-resize")
                #expect(abs(screen.frame.width - root.bounds.width) < 0.5)
            }
        }
        // The resize ended: the next layout change springs as it did before. Pinned, because another
        // test's window can be in a resize of its own on a busy host.
        let otherWindowsResizing = LiveResizeWindows.shared.isActive
        Motion.liveResizeOverride = false
        defer { Motion.liveResizeOverride = nil }
        model.apply(screens: Self.split(0.6))
        root.syncWithModel()
        #expect(!settled("p1"), "a layout change after the resize did not animate (moves \(Motion.panes.animatesMovement), other windows resizing \(otherWindowsResizing))")
    }

    @Test func aTabStripThatStartsOverflowingMidDragFadesItsEdgeAtOnce() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesFades, "animation speed is off on this host")
        let tabs = (0..<8).map { CmuxNextTabs.TabItem(id: CmuxNextTabs.TabID("tab\($0)"), title: "Tab \($0)") }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: CmuxNextTabs.TabID("tab0")))
        let window = Self.window(width: 1600, height: 40)
        defer { window.closeAfterTest() }
        window.contentView = strip
        strip.frame = NSRect(x: 0, y: 0, width: 1600, height: TabStripView.preferredHeight)
        strip.layoutSubtreeIfNeeded()
        try #require(!strip.edgeFade.edges.trailing, "eight tabs overflow a 1600 pt strip")

        Self.liveResize {
            // The window narrows until the tabs no longer fit.
            for width in stride(from: 1400, through: 200, by: -100) {
                strip.setFrameSize(NSSize(width: CGFloat(width), height: strip.frame.height))
                strip.layoutSubtreeIfNeeded()
                #expect((strip.edgeFade.mask.animationKeys() ?? []).isEmpty, "\(width) pt: the edge fade animates mid-resize")
            }
        }
        #expect(strip.edgeFade.edges.trailing, "the narrowed strip's tabs fit; the test proves nothing")
    }

    @Test func aWindowIsInALiveResizeFromItsStartToItsEndOrClose() {
        let center = NotificationCenter()
        let windows = LiveResizeWindows(center: center)
        let window = Self.window(width: 800, height: 600)
        defer { window.closeAfterTest() }
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        #expect(windows.isActive)
        center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        #expect(!windows.isActive)
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!windows.isActive, "a window closed mid-drag still holds every spring")
    }
}
