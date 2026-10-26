import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// Visibility from the motion plan (chrome-parity p03-rendering-106): the pass at a change's apply reads where
/// each pane shows now and where it rests, so a pane that enters is visible in the change's turn and one that
/// leaves stays visible until the motion lands; the frame that lands narrows to the rest. No display frame in
/// between runs the pass (`debug.layout_counters` `update_visibility` <= 2 per spring, p03-rendering DC2), and
/// each pane the change moves in or out hears one presence change. Frames step at a fixed 120 Hz dt.
@MainActor
struct PaneVisibilityPlanTests {
    /// Every presence change the root reported, per pane, in order.
    final class Presences: LayoutPaneContentProvider {
        var changes: [PaneID: [PanePresence]] = [:]

        func makeContentView(for pane: PaneID) -> NSView { NSView() }

        func panePresenceDidChange(_ pane: PaneID, presence: PanePresence) {
            changes[pane, default: []].append(presence)
        }
    }

    final class Screen {
        let provider = Presences()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ layout: ScreenLayout, focused: PaneID) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
            model.splitSizingOverride = .even
            // Full-width columns with no gap: a column beside the one shown is wholly off screen.
            model.followsDesignMetrics = false
            model.baseStyle.columnGap = 0
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
            provider.changes = [:]
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        /// The layout and its focus in one change turn (a key's provisional change).
        func change(to layout: ScreenLayout, focus: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            model.focus(focus, notify: false)
            root.syncWithModel()
        }

        /// The app's order for a close (`WorkspaceContentController.apply`): the daemon's tree, then the focus.
        func close(to layout: ScreenLayout, focus: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
            model.focus(focus, notify: false)
            root.syncWithModel()
        }

        /// Steps the springs to rest; returns the visibility passes the frames before the landing ran, and false
        /// for `landed` if they still move after 5 s.
        func stepToRest() -> (landed: Bool, passesOnTheWay: UInt64) {
            var onTheWay: UInt64 = 0
            for _ in 0..<600 {
                let before = root.visibilityUpdates
                guard root.advanceFrame(1.0 / 120) else { return (true, onTheWay) }
                onTheWay += root.visibilityUpdates - before
            }
            return (false, onTheWay)
        }
    }

    static let pair: ScreenLayout = .splits(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))

    @Test func cmdDShowsTheNewPaneInTheKeysTurnWithTwoPasses() throws {
        let fixture = Screen(.splits(.leaf("a")), focused: "a")
        let passes = fixture.root.visibilityUpdates
        fixture.change(to: Self.pair, focus: "b")
        try #require(fixture.screen.hasMotion, "the split does not spring on the CPU")
        #expect(fixture.model.visiblePanes == ["a", "b"], "the new pane is not visible in the key's turn: \(fixture.model.visiblePanes)")
        #expect(fixture.provider.changes["b"] == [.visible])
        let (landed, onTheWay) = fixture.stepToRest()
        #expect(landed, "the split did not land")
        #expect(onTheWay == 0, "\(onTheWay) visibility passes ran on frames before the landing")
        #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
        #expect(fixture.provider.changes == ["b": [.visible]], "presence changes \(fixture.provider.changes)")
    }

    /// New Column: the camera springs to the new full-width column. The new pane is visible in the key's turn,
    /// the old one stays visible while it slides out and goes to the keep-alive band once, at the landing.
    @Test func newColumnEntersInTheKeysTurnAndTheOldOneLeavesAtTheLanding() throws {
        let fixture = Screen(ColumnCloseScrollMotionTests.columns(1, width: 1), focused: "p1")
        let passes = fixture.root.visibilityUpdates
        fixture.change(to: ColumnCloseScrollMotionTests.columns(2, width: 1), focus: "p2")
        try #require(fixture.screen.hasMotion, "the camera does not spring to the new column")
        #expect(fixture.model.visiblePanes == ["p1", "p2"], "visible in the key's turn: \(fixture.model.visiblePanes)")
        let (landed, onTheWay) = fixture.stepToRest()
        #expect(landed, "the camera did not land")
        #expect(onTheWay == 0, "\(onTheWay) visibility passes ran on frames before the landing")
        #expect(fixture.model.visiblePanes == ["p2"], "visible at rest: \(fixture.model.visiblePanes)")
        #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
        #expect(fixture.provider.changes == ["p2": [.visible], "p1": [.keepAlive]], "presence changes \(fixture.provider.changes)")
    }

    /// Cmd-W on the focused last full-width column: the column left of it slides back in and is visible in the
    /// close's turn; the focus that comes in the next turn moves nothing the pass reads.
    @Test func cmdWBringsTheNeighbourInInTheClosesTurn() throws {
        let fixture = Screen(ColumnCloseScrollMotionTests.columns(2, width: 1), focused: "p2")
        try #require(fixture.model.visiblePanes == ["p2"], "p2 shows alone before the close: \(fixture.model.visiblePanes)")
        let passes = fixture.root.visibilityUpdates
        fixture.close(to: ColumnCloseScrollMotionTests.columns(1, width: 1), focus: "p1")
        try #require(fixture.screen.hasMotion, "the close does not spring on the CPU")
        #expect(fixture.model.visiblePanes == ["p1"], "p1 is not visible in the close's turn: \(fixture.model.visiblePanes)")
        let (landed, onTheWay) = fixture.stepToRest()
        #expect(landed, "the close did not land")
        #expect(onTheWay == 0, "\(onTheWay) visibility passes ran on frames before the landing")
        #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
        #expect(fixture.provider.changes == ["p1": [.visible], "p2": [.hidden]], "presence changes \(fixture.provider.changes)")
    }
}

/// The same on the render server (`motion.renderServer` on): the change's turn puts every frame at rest and the
/// plan's springs hold where each pane sweeps (``ScreenContentView/RenderTracks``) until they land, so the panes
/// they carry stay visible on the way and the landing narrows once. Real windows ordered in (a window on no
/// screen does not animate): runs with the pane bench (CMUX_PANE_BENCH=1), not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct PaneVisibilityPlanRenderServerTests {
    typealias Render = SplitRenderMotionTests

    @Test func cmdDOnTheRenderServerShowsTheNewPaneInTheKeysTurnAndLandsWithOnePass() async throws {
        try await Render.withMotion {
            let split = Render.Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let passes = split.root.visibilityUpdates
            split.split()
            #expect(split.model.visiblePanes == ["a", "b"], "the new pane is not visible in the key's turn")
            #expect(split.root.visibilityUpdates - passes == 1, "the key's turn ran \(split.root.visibilityUpdates - passes) passes")
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(split.root.visibilityUpdates - passes <= 2, "\(split.root.visibilityUpdates - passes) passes for one spring")
            #expect(split.model.visiblePanes == ["a", "b"])
        }
    }

    /// Closing the focused last of three half-width columns: p1 slides in from the left on the close's spring.
    @Test func closingTheLastColumnShowsTheColumnItBringsInInTheClosesTurn() async throws {
        try await Render.withMotion {
            let fixture = CloseRenderMotionTests.Screen(ColumnCloseScrollMotionTests.columns(3), focused: "p3")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            try #require(!fixture.model.visiblePanes.contains("p1"), "p1 shows before the close: \(fixture.model.visiblePanes)")
            let passes = fixture.root.visibilityUpdates
            fixture.close(to: ColumnCloseScrollMotionTests.columns(2), focus: "p2")
            try #require(!fixture.screen.renderTracks.isEmpty, "the render server did not take the close")
            #expect(fixture.model.visiblePanes == ["p1", "p2"], "visible in the close's turn: \(fixture.model.visiblePanes)")
            #expect(await fixture.landed(), "the close did not land in 5 s")
            #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
            #expect(fixture.model.visiblePanes == ["p1", "p2"])
        }
    }
}
