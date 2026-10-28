import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// Visibility from the motion plan: the pass at a change's apply reads where
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

        /// Panes a frame on the way showed (more than a point of them in the viewport) while the root reported them
        /// not visible, since the fixture was made.
        var shownUnreported: Set<PaneID> = []

        /// With `renderServer`, `motion.renderServer` is on and the window is ordered in (a window on no screen
        /// does not animate); the CPU's frames still step by hand.
        init(_ layout: ScreenLayout, focused: PaneID, renderServer: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
            model.splitSizingOverride = .even
            // Full-width columns with no gap: a column beside the one shown is wholly off screen.
            model.followsDesignMetrics = false
            model.baseStyle.columnGap = 0
            root = LayoutRootView(model: model, contentProvider: provider, rendersMotionOnServer: { renderServer },
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: !renderServer)
            window.isReleasedWhenClosed = false
            window.contentView = root
            if renderServer { window.orderFrontRegardless() }
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
        /// for `landed` if they still move after 5 s. Each frame adds what it shows unreported to ``shownUnreported``.
        func stepToRest() -> (landed: Bool, passesOnTheWay: UInt64) {
            var onTheWay: UInt64 = 0
            for _ in 0..<600 {
                let before = root.visibilityUpdates
                let moving = root.advanceFrame(1.0 / 120)
                noteShownUnreported()
                guard moving else { return (true, onTheWay) }
                onTheWay += root.visibilityUpdates - before
            }
            return (false, onTheWay)
        }

        /// The panes this frame shows in the viewport that the root does not report visible.
        func noteShownUnreported() {
            for (pane, frame) in screen.paneFrames where frame.alpha.value > 0.01 && !model.visiblePanes.contains(pane) {
                guard let shown = screen.displayedFrame(of: pane) else { continue }
                let overlap = shown.intersection(screen.bounds)
                if !overlap.isNull, overlap.width > 1, overlap.height > 1 { shownUnreported.insert(pane) }
            }
        }

        func close() {
            window.orderOut(nil)
            window.close()
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
        #expect(fixture.shownUnreported.isEmpty, "shown but not visible on the way: \(fixture.shownUnreported)")
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
        #expect(fixture.shownUnreported.isEmpty, "shown but not visible on the way: \(fixture.shownUnreported)")
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
        #expect(fixture.shownUnreported.isEmpty, "shown but not visible on the way: \(fixture.shownUnreported)")
        #expect(onTheWay == 0, "\(onTheWay) visibility passes ran on frames before the landing")
        #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
        #expect(fixture.provider.changes == ["p1": [.visible], "p2": [.hidden]], "presence changes \(fixture.provider.changes)")
    }

    /// A camera thrown with velocity (a fling's release, a retarget that keeps its speed) passes its rest on the
    /// scroll spring: the full-width neighbour shows for some frames, then the camera comes back. The pass in the
    /// throw's turn reads the camera's whole way, overshoot included, so the neighbour is visible on every frame
    /// that shows it, and the landing narrows once.
    @Test func aCameraThrownPastItsRestKeepsTheNeighbourItShowsVisible() throws {
        let fixture = Screen(ColumnCloseScrollMotionTests.columns(2, width: 1), focused: "p1")
        try #require(fixture.model.visiblePanes == ["p1"], "p1 shows alone before the throw: \(fixture.model.visiblePanes)")
        let passes = fixture.root.visibilityUpdates
        // Toward p2: the strip's offset grows past its rest at 0, so its content moves left.
        var camera = fixture.screen.scroll
        camera.velocity = 2400
        fixture.screen.scroll = camera
        fixture.root.updateVisibility()
        try #require(fixture.screen.hasMotion, "the camera does not spring")
        #expect(fixture.model.visiblePanes == ["p1", "p2"], "the overshoot's neighbour is not visible in the throw's turn")
        let (landed, onTheWay) = fixture.stepToRest()
        #expect(landed, "the thrown camera did not land")
        #expect(fixture.shownUnreported.isEmpty, "shown but not visible on the way: \(fixture.shownUnreported)")
        #expect(onTheWay == 0, "\(onTheWay) visibility passes ran on frames before the landing")
        #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
        #expect(fixture.model.visiblePanes == ["p1"], "visible at rest: \(fixture.model.visiblePanes)")
        #expect(fixture.provider.changes == ["p2": [.visible, .keepAlive]], "presence changes \(fixture.provider.changes)")
    }

    /// A strip pan during a spring: the frames move under the span the last pass recorded, so no pan event skips
    /// the pass (`panKeepsVisibility`). At rest, a pan event skips it only when a pass would report nothing new.
    @Test func aPanDuringASpringRunsThePassOnEachEvent() throws {
        let fixture = Screen(ColumnCloseScrollMotionTests.columns(2, width: 1), focused: "p1")
        fixture.change(to: Self.splitFirstColumn, focus: "p9")
        try #require(fixture.screen.hasMotion, "the split does not spring on the CPU")
        fixture.screen.beginUserScroll()
        fixture.screen.userScroll(deltaX: -2, timestamp: 1)
        #expect(!fixture.screen.panKeepsVisibility, "a pan event during the split would skip the pass")
        fixture.screen.endUserScroll(timestamp: 1.01)
        _ = fixture.stepToRest()
        try #require(!fixture.screen.hasMotion, "the split did not land")
        fixture.root.updateVisibility()
        fixture.screen.beginUserScroll()
        fixture.screen.userScroll(deltaX: -2, timestamp: 2)
        if fixture.screen.panKeepsVisibility {
            #expect(fixture.screen.visiblePanes() == fixture.model.visiblePanes, "a skipped pass would have reported a change")
        }
        fixture.screen.endUserScroll(timestamp: 2.01)
        _ = fixture.stepToRest()
    }

    /// Cmd-D on the first of two full-width columns: `p9` grows in beside `p1`.
    static let splitFirstColumn: ScreenLayout = .columns([
        LayoutColumn(id: "c1", width: 1, root: .split(SplitID("n"), axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p9"))),
        LayoutColumn(id: "c2", width: 1, root: .leaf("p2")),
    ])
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

    /// New Column with full-width columns: the new pane springs in on the render server and the camera on the CPU.
    /// The column that leaves stays visible until both land, and the landing moves it to the keep-alive band once.
    @Test func newColumnOnTheRenderServerNarrowsTheColumnThatLeftAtTheLanding() async throws {
        try await Render.withMotion {
            let fixture = PaneVisibilityPlanTests.Screen(ColumnCloseScrollMotionTests.columns(1, width: 1), focused: "p1", renderServer: true)
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let passes = fixture.root.visibilityUpdates
            fixture.change(to: ColumnCloseScrollMotionTests.columns(2, width: 1), focus: "p2")
            #expect(fixture.model.visiblePanes == ["p1", "p2"], "visible in the key's turn: \(fixture.model.visiblePanes)")
            let (landed, onTheWay) = fixture.stepToRest()
            #expect(landed, "the camera did not land")
            #expect(onTheWay == 0, "\(onTheWay) visibility passes ran on frames before the landing")
            #expect(await Render.until { fixture.screen.renderSpringsInFlight == 0 }, "the render server's springs did not land in 5 s")
            #expect(fixture.model.visiblePanes == ["p2"], "visible at rest: \(fixture.model.visiblePanes)")
            #expect(fixture.root.visibilityUpdates - passes <= 2, "\(fixture.root.visibilityUpdates - passes) passes for one spring")
            #expect(fixture.provider.changes == ["p2": [.visible], "p1": [.keepAlive]], "presence changes \(fixture.provider.changes)")
        }
    }

    /// A strip pan whose finger is still down when the render server's springs land: the landing runs the pass,
    /// though the layout motion goes on with the pan (`renderSpringLanded`).
    @Test func aPanHeldAcrossTheRenderServerLandingStillNarrows() async throws {
        try await Render.withMotion {
            let fixture = PaneVisibilityPlanTests.Screen(ColumnCloseScrollMotionTests.columns(2, width: 1), focused: "p1", renderServer: true)
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.change(to: PaneVisibilityPlanTests.splitFirstColumn, focus: "p9")
            try #require(!fixture.screen.renderTracks.panes.isEmpty, "the render server did not take the split")
            fixture.screen.beginUserScroll()
            let passes = fixture.root.visibilityUpdates
            #expect(await Render.until { fixture.screen.renderSpringsInFlight == 0 }, "the render server's springs did not land in 5 s")
            #expect(fixture.screen.isGesturing, "the pan let go before the landing")
            #expect(fixture.root.visibilityUpdates > passes, "the landing ran no pass with the pan held")
            #expect(fixture.model.visiblePanes == fixture.screen.visiblePanes(), "the report is not the rest's")
            fixture.screen.endUserScroll(timestamp: 1)
            _ = fixture.stepToRest()
        }
    }
}
