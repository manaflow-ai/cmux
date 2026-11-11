import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Motion design removal 10 (plans/cmux-next/motion-first-principles-DESIGN.md): a live resize or
/// a full screen transition of one window snaps movement in THAT window only. A person who drags
/// the edge of window A still sees a tab strip fade and a pane spring in window B.
///
/// A window enters a live resize through AppKit's `willStartLiveResize` notification, which a
/// test posts to a private center for its own window (AppKit's resize tracking needs a real
/// pointer). Every test is synchronous, so the tracker it installs cannot leak into another test.
@MainActor @Suite(.serialized, .closesItsWindows) struct LiveResizePerWindowTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: CmuxNextLayout.PaneID) -> NSView { NSView() }
    }

    /// `body` runs with the app's live-resize tracker on a private center; post a window's
    /// notifications to that center as AppKit posts them to the default one.
    static func tracked(_ body: (NotificationCenter) throws -> Void) rethrows {
        let center = NotificationCenter()
        let app = LiveResizeWindows.shared
        LiveResizeWindows.shared = LiveResizeWindows(center: center)
        defer { LiveResizeWindows.shared = app }
        try body(center)
    }

    static func window(width: CGFloat = 1000, height: CGFloat = 700) -> NSWindow {
        LiveResizeTrackingTests.window(width: width, height: height)
    }

    static let gates: [MotionGate] = [Motion.panes, Motion.tabs, Motion.sidebar, Motion.overlays]

    @Test func aLiveResizeSnapsMovementInItsOwnWindowOnly() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesMovement, "animation speed is off on this host")
        let resized = Self.window(), other = Self.window()
        defer { resized.closeAfterTest(); other.closeAfterTest() }
        Self.tracked { center in
            center.post(name: NSWindow.willStartLiveResizeNotification, object: resized)
            for gate in Self.gates {
                #expect(!gate.animatesMovement(in: resized), "\(gate.category): the window under the drag springs toward a size the next frame replaces")
                #expect(gate.policy(in: resized).liveResize)
                #expect(gate.animatesMovement(in: other), "\(gate.category): a live resize of one window snaps movement in another window")
                #expect(!gate.policy(in: other).liveResize)
                #expect(gate.policy(in: other).animatesFades && gate.policy(in: resized).animatesFades, "a live resize stops no fade")
            }
            center.post(name: NSWindow.didEndLiveResizeNotification, object: resized)
            for gate in Self.gates {
                #expect(gate.animatesMovement(in: resized), "\(gate.category): the resize ended; movement animates again")
            }
        }
    }

    @Test func aFullScreenTransitionSnapsMovementInItsOwnWindowOnly() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesMovement, "animation speed is off on this host")
        let entering = Self.window(), other = Self.window()
        defer { entering.closeAfterTest(); other.closeAfterTest() }
        Self.tracked { center in
            for (start, end) in [(NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification),
                                 (NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification)] {
                center.post(name: start, object: entering)
                for gate in Self.gates {
                    #expect(!gate.animatesMovement(in: entering), "\(gate.category): content springs toward a size inside the transition")
                    #expect(gate.animatesMovement(in: other), "\(gate.category): a full screen transition of one window snaps movement in another window")
                }
                center.post(name: end, object: entering)
                for gate in Self.gates {
                    #expect(gate.animatesMovement(in: entering), "\(gate.category): the transition ended; movement animates again")
                }
            }
        }
    }

    @Test func aTabStripInAnotherWindowFadesItsEdgeWhileAWindowIsResized() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.tabs.animatesFades, "animation speed is off on this host")
        func makeStrip(in window: NSWindow) throws -> TabStripView {
            let tabs = (0..<8).map { CmuxNextTabs.TabItem(id: CmuxNextTabs.TabID("tab\($0)"), title: "Tab \($0)") }
            let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: CmuxNextTabs.TabID("tab0")))
            window.contentView = strip
            strip.frame = NSRect(x: 0, y: 0, width: 1600, height: TabStripView.preferredHeight)
            strip.layoutSubtreeIfNeeded()
            try #require(!strip.edgeFade.edges.trailing, "eight tabs overflow a 1600 pt strip")
            return strip
        }
        /// The strip narrows until its tabs no longer fit; true when the edge fade animated in.
        func fadesInWhenNarrowed(_ strip: TabStripView) -> Bool {
            strip.setFrameSize(NSSize(width: 200, height: strip.frame.height))
            strip.layoutSubtreeIfNeeded()
            return (strip.edgeFade.mask.animationKeys() ?? []).contains("colors")
        }
        let resized = Self.window(width: 1600, height: 40), other = Self.window(width: 1600, height: 40)
        defer { resized.closeAfterTest(); other.closeAfterTest() }
        let resizedStrip = try makeStrip(in: resized), otherStrip = try makeStrip(in: other)
        Self.tracked { center in
            center.post(name: NSWindow.willStartLiveResizeNotification, object: resized)
            #expect(fadesInWhenNarrowed(otherStrip), "a live resize of one window stops the edge fade of a tab strip in another window")
            #expect(!fadesInWhenNarrowed(resizedStrip), "the edge fade animates in the window under the drag")
        }
        #expect(otherStrip.edgeFade.edges.trailing && resizedStrip.edgeFade.edges.trailing, "the narrowed strips' tabs fit; the test proves nothing")
    }

    @Test func aPaneLayoutChangeInAnotherWindowSpringsWhileAWindowIsResized() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        // Pane layout springs only with `ui.paneAnimations` on.
        let paneAnimations = DesignSettings.shared.paneAnimations
        DesignSettings.shared.paneAnimations = true
        defer { DesignSettings.shared.paneAnimations = paneAnimations }
        try #require(Motion.panes.animatesMovement, "animation speed is off on this host")
        let provider = Panes()
        /// A two-pane root in `window`; `moved()` lands another client's divider move and says
        /// whether a pane is now away from its target (it springs) or already there (it snapped).
        func makeRoot(in window: NSWindow) throws -> (LayoutRootView, () -> Bool) {
            let model = LayoutModel(screens: LiveResizeTrackingTests.split(0.5), activeScreenID: "s", focusedPane: "p1")
            let root = LayoutRootView(model: model, contentProvider: provider)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            let screen = try #require(root.screenViews["s"])
            return (root, {
                model.apply(screens: LiveResizeTrackingTests.split(0.3))
                root.syncWithModel()
                guard let shown = screen.displayedFrame(of: "p1"), let target = screen.geometry.panes["p1"] else { return false }
                return abs(shown.width - target.width) >= 0.5
            })
        }
        let resized = Self.window(), other = Self.window()
        defer { resized.closeAfterTest(); other.closeAfterTest() }
        let (resizedRoot, resizedMoved) = try makeRoot(in: resized)
        let (otherRoot, otherMoved) = try makeRoot(in: other)
        Self.tracked { center in
            center.post(name: NSWindow.willStartLiveResizeNotification, object: resized)
            #expect(otherMoved(), "a live resize of one window snaps a pane layout change in another window")
            #expect(!resizedMoved(), "a pane springs toward the layout in the window under the drag")
        }
        _ = (resizedRoot, otherRoot)
    }
}
