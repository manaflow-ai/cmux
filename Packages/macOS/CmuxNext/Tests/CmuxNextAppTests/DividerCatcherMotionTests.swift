import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Lawrence (2026-10-23): splits lag, more with Chromium pages. While a page window shows, every
/// divider hit area has a click-catching panel above the pages (`DividerMouseCatchers`). Each
/// frame of a split, close, zoom or New Column moved the dividers, so each frame moved every moving
/// divider's panel (one window server move each, a new panel for a new divider) and re-ran divider
/// hover: at 30 panes 64 % of `advanceFrame` (PL-motion-core profile, cmux10s, b553d0648b1). Nobody
/// grabs a divider on a spring: the window's catcher areas, which every panel follows, change once
/// when the layout lands and never during the motion.
@MainActor @Suite(.serialized) struct DividerCatcherMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shell window whose content is a layout of two side-by-side panes, its overlay layer
    /// adopting the layout's plane, as the app wires them; the test drives the frames.
    struct Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()

        init() {
            _ = NSApplication.shared
            let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            settle()
        }

        @discardableResult
        func settle() -> Int {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            return frames
        }

        var catcherAreas: [CGRect] { window.overlayLayer.catcherAreas.map(\.rect) }
        var dividerAreas: [CGRect] { window.overlayLayer.dividerAreas.map(\.rect) }
    }

    @Test func aSplitMovesNoCatcherAreaUntilItLands() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let before = layout.catcherAreas
        try #require(!before.isEmpty, "the split's divider has a catcher area: \(layout.window.overlayLayer.dividerAreas)")

        // A third pane splits off the right one: the existing divider springs left, a new one grows in.
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()

        var springFrames = 0, catcherChangesInMotion = 0, dividerChangesInMotion = 0, passThroughFrames = 0
        var lastCatchers = layout.catcherAreas, lastDividers = layout.dividerAreas
        let restingIDs = Set(layout.window.overlayLayer.catcherAreas.map(\.id))
        while springFrames < 480, layout.root.advanceFrame(1.0 / 120) {
            springFrames += 1
            if layout.catcherAreas != lastCatchers { catcherChangesInMotion += 1 }
            if layout.dividerAreas != lastDividers { dividerChangesInMotion += 1 }
            if layout.window.overlayLayer.catcherPassThrough == restingIDs { passThroughFrames += 1 }
            (lastCatchers, lastDividers) = (layout.catcherAreas, layout.dividerAreas)
        }
        try #require(springFrames > 4 && dividerChangesInMotion > 4, "the split animated: \(springFrames) frames, dividers moved \(dividerChangesInMotion)")
        // The frame the spring landed in returned false: the catchers follow there, once.
        #expect(catcherChangesInMotion <= 1, "catcher areas changed on \(catcherChangesInMotion) of \(springFrames) spring frames")
        #expect(layout.catcherAreas == layout.dividerAreas, "at rest the catchers cover the dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
        #expect(layout.catcherAreas.count == before.count + 1, "the new split's divider has its area at rest: \(before) -> \(layout.catcherAreas)")
        // A catcher left where its divider was must not swallow a click on the page there.
        #expect(passThroughFrames >= springFrames - 1, "the resting catchers let the mouse through on \(passThroughFrames) of \(springFrames) spring frames")
        #expect(layout.window.overlayLayer.catcherPassThrough.isEmpty, "at rest every catcher takes the mouse: \(layout.window.overlayLayer.catcherPassThrough)")
    }

    /// A root hidden mid-spring (a workspace switch during a split) settles its springs with the
    /// display link detached, so no frame reports the landing. It read as still moving when it
    /// showed again, and the window kept its catcher panels where they were (at the other
    /// workspace's dividers) until a later spring in this workspace landed: clicks on the pages
    /// under them were lost and the real dividers took no mouse over a page.
    @Test func aRootHiddenMidSpringShowsAgainWithItsCatchersAtRest() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()
        for _ in 0..<3 { _ = layout.root.advanceFrame(1.0 / 120) }
        try #require(layout.root.isInLayoutMotion, "the split is mid-spring")

        layout.root.isHidden = true
        #expect(!layout.root.isLive && !layout.root.isLayoutInMotion, "a parked root runs no motion")
        layout.root.isHidden = false
        try #require(layout.root.isLive, "the root shows again")

        #expect(!layout.root.isInLayoutMotion, "the settled split is at rest")
        #expect(layout.catcherAreas == layout.dividerAreas, "the catchers cover this root's dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
        #expect(layout.dividerAreas.count == 2, "both dividers of the landed split: \(layout.dividerAreas)")
        #expect(layout.window.overlayLayer.catcherPassThrough.isEmpty, "every catcher takes the mouse")
    }
}
