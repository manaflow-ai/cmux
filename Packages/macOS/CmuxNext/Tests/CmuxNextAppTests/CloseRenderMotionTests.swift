import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import QuartzCore
import Testing

/// A close on the render server (`motion.renderServer` on): Cmd-W on
/// either axis and the close of the last column put every pane and divider at rest in the change's turn,
/// with the strip camera (and each row column's) at rest in the model too. The camera rides the close's
/// frame spring as part of each pane's own spring (Lawrence 2026-10-20), so the main thread steps nothing
/// per frame, the landing runs once, and a leading-column report the camera owed goes out at the landing.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct CloseRenderMotionTests {
    typealias Render = SplitRenderMotionTests

    /// The `motion.renderServer` switch, read in each change turn.
    final class Switch {
        var isOn: Bool

        init(_ isOn: Bool) { self.isOn = isOn }
    }

    /// One screen `s` in a 1200 x 800 window, with what the root announced and reported.
    final class Screen {
        let panes = SplitRenderMotionTests.Panes()
        let renderServer: Switch
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Every layout motion start (true) and end (false) the root announced.
        var motion: [Bool] = []
        /// Every leading column the screen reported to the daemon (`LayoutIntent.scrollTo`).
        var reported: [ColumnID] = []
        private var observation: LayoutOverlaySyncObservation?
        private var landing: CheckedContinuation<Bool, Never>?

        /// `columnGap`: pins the layout style with that column gap (`followsDesignMetrics` off), so the geometry does
        /// not follow the host's design settings; nil (the default) keeps the live design metrics, as before.
        init(_ layout: ScreenLayout, focused: PaneID, renderServer: Bool = true, reduceMotion: Bool = false, columnGap: CGFloat? = nil) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
            if let columnGap {
                model.followsDesignMetrics = false
                model.baseStyle.columnGap = columnGap
                model.baseStyle.panePadding = 0
            }
            model.rowsEnabledOverride = true
            let renderSwitch = Switch(renderServer)
            self.renderServer = renderSwitch
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderSwitch.isOn }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            model.intentHandler = { [weak self] intent in
                if case let .scrollTo(_, column) = intent { self?.reported.append(column) }
            }
            observation = root.observeLayoutMotion { [weak self] moving in
                guard let self else { return }
                motion.append(moving)
                if !moving { resumeLanding(true) }
            }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func host(_ pane: PaneID) throws -> PaneHostView { try #require(root.context.hosts[pane]) }

        /// The app's order for a close (`WorkspaceContentController.apply`): the daemon's tree in one turn,
        /// then the focus the topology lands in the next.
        func close(to layout: ScreenLayout, focus: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
            model.focus(focus, notify: false)
            root.syncWithModel()
        }

        /// The daemon's tree after a close, in its own turn (the focus comes in the next: ``focus(_:)``).
        func apply(_ layout: ScreenLayout) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
        }

        func focus(_ pane: PaneID) {
            model.focus(pane, notify: false)
            root.syncWithModel()
        }

        /// The leading column at the strip camera's rest: what the daemon should hear once it lands.
        var restingLeadingColumn: ColumnID? {
            let geometry = screen.geometry
            return ColumnStripGeometry.leadingColumnIndex(frames: geometry.orderedColumnFrames, offset: screen.scroll.target,
                                                          gap: root.context.style.stripGap).map { geometry.columnOrder[$0] }
        }

        /// Steps the CPU springs to rest (the driver is manual); false if they still move after 4 s.
        func stepToRest() -> Bool {
            for _ in 0..<480 where !root.advanceFrame(1.0 / 120) { return true }
            return false
        }

        /// Waits until every render-server spring the screen started has landed (its completion ran).
        func renderSpringsDrained() async -> Bool {
            await SplitRenderMotionTests.until { screen.renderSpringsInFlight == 0 }
        }

        /// Waits for the layout motion to end; false after `timeout`.
        func landed(timeout: Duration = .seconds(5)) async -> Bool {
            if motion.last == false { return true }
            return await withCheckedContinuation { continuation in
                landing = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeLanding(false)
                }
            }
        }

        private func resumeLanding(_ landed: Bool) {
            landing?.resume(returning: landed)
            landing = nil
        }

        func close() {
            observation = nil
            window.orderOut(nil)
            window.close()
        }
    }

    static func pair(_ axis: SplitAxis) -> ScreenLayout {
        .splits(.split(SplitID("d"), axis: axis, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
    }

    /// The backing layer of `pane`'s host.
    static func layer(_ fixture: Screen, _ pane: PaneID) throws -> CALayer {
        let host = try fixture.host(pane)
        return try #require(host.layer)
    }

    /// The rest the turn left: every host and divider at its spring's target, and no CPU spring to step.
    static func expectAtRest(_ fixture: Screen, _ panes: [PaneID]) throws {
        let screen = fixture.screen
        #expect(!screen.hasMotion, "a CPU spring is left to step")
        #expect(!screen.leadsFrame, "the close kept its CPU first frame")
        #expect(!fixture.root.driver.isRunning, "the close asked the window's MotionClock for layout frames")
        #expect(abs(screen.scroll.value - screen.scroll.target) < 0.01, "the strip camera is not at rest in the model")
        for pane in panes {
            let host = try fixture.host(pane)
            let rest = try #require(screen.displayedFrame(of: pane))
            #expect(Render.gap(host.frame, rest) < 0.5, "\(pane) shows \(host.frame), not its rest \(rest)")
        }
        for (kind, frame) in screen.dividerFrames {
            #expect(frame.rect == frame.targetRect, "divider \(kind) still springs on the CPU")
        }
    }

    @Test(arguments: [SplitAxis.horizontal, .vertical])
    func cmdWRestsInTheKeysTurnAndSpringsOnTheRenderServer(_ axis: SplitAxis) async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.pair(axis), focused: "b")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            // In the layer's own space, as the presentation reads it.
            let before = try Self.layer(fixture, "a").frame
            Render.freeze(clock)
            fixture.close(to: .splits(.leaf("a")), focus: "a")
            try Self.expectAtRest(fixture, ["a"])
            #expect(fixture.motion == [true], "the layout motion starts in the key's turn and has not landed")
            let host = try fixture.host("a")
            #expect(host.isOnRenderSpring && host.isOnLayoutSpring, "a is not on its spring")
            // Half way along the close spring, a shows half way between where it showed and its rest.
            let layer = try #require(host.layer)
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(fixture.screen.motionState.frameSpring))
            let from = try Render.presented(layer, at: 0, root: clock)
            let shown = try Render.presented(layer, at: half, root: clock)
            #expect(Render.gap(from, before) <= 0.5, "a jumped from \(before) to \(from) in the close's turn")
            #expect(Render.gap(from, layer.frame) > 100, "a does not move: \(from) to \(layer.frame)")
            let expected = Render.midpoint(from, layer.frame)
            #expect(Render.gap(shown, expected) <= 1, "a shows \(shown) half way, not \(expected)")
        }
    }

    /// Closing the focused last column, scrolled to the end: the panes left and the camera that brings
    /// them back into the window are one spring per pane, from where it showed to where it rests.
    @Test func closingTheLastColumnShiftsTheCameraOnTheFrameSpring() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(3), focused: "p3")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            try #require(fixture.screen.scroll.value > 100, "three half-width columns scroll to the end for p3")
            let clock = try #require(fixture.root.layer)
            let before = try (Self.layer(fixture, "p1").frame, Self.layer(fixture, "p2").frame)
            Render.freeze(clock)
            fixture.close(to: ColumnCloseScrollMotionTests.columns(2), focus: "p2")
            #expect(fixture.root.context.hosts["p3"]?.superview == nil, "the closed pane leaves at once")
            try Self.expectAtRest(fixture, ["p1", "p2"])
            #expect(abs(fixture.screen.scroll.target) < 0.5, "two half-width columns fit: the camera rests at 0")
            #expect(fixture.motion == [true])
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(fixture.screen.motionState.frameSpring))
            for (pane, shownBefore) in [("p1", before.0), ("p2", before.1)] as [(PaneID, CGRect)] {
                let layer = try Self.layer(fixture, pane)
                let from = try Render.presented(layer, at: 0, root: clock)
                #expect(Render.gap(from, shownBefore) <= 0.5, "\(pane) jumped from \(shownBefore) to \(from) in the close's turn")
                #expect(from.minX + 100 < layer.frame.minX, "\(pane) does not slide right with the camera: \(from) to \(layer.frame)")
                let shown = try Render.presented(layer, at: half, root: clock)
                let expected = Render.midpoint(from, layer.frame)
                #expect(Render.gap(shown, expected) <= 1, "\(pane) shows \(shown) half way, not \(expected)")
            }
        }
    }

    /// A close lands once: one motion start and one end, nothing left on a spring, no frames asked, and the
    /// leading-column report a wheel notch's camera owed goes out then, once, for the column at rest.
    @Test func theCloseLandsOnceAndReportsTheLeadingColumnThen() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(4), focused: "p4")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.screen.discreteScroll(direction: -1)
            try #require(fixture.screen.reportScrollOnSettle, "the wheel notch's camera owes no report")
            fixture.close(to: ColumnCloseScrollMotionTests.columns(3), focus: "p3")
            #expect(fixture.reported.isEmpty, "the leading column went out before the camera landed: \(fixture.reported)")
            #expect(!fixture.screen.reportScrollOnSettle, "the report waits for a CPU camera frame")
            #expect(await fixture.landed(), "the close did not land in 5 s")
            #expect(fixture.motion == [true, false], "layout motion \(fixture.motion)")
            let expected = try #require(fixture.restingLeadingColumn)
            #expect(fixture.reported == [expected], "reported \(fixture.reported), not the resting column \(expected)")
            #expect(fixture.screen.renderSpringsInFlight == 0)
            #expect(fixture.screen.renderTracks.isEmpty, "a landed close keeps its spring records")
            #expect(!fixture.screen.scrollRidesFrames, "the camera still rides a landed close")
            #expect(!fixture.root.driver.isRunning, "the landing asked for layout frames")
            for pane: PaneID in ["p1", "p2", "p3"] {
                let host = try fixture.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring, "\(pane) is still on its spring")
            }
        }
    }

    /// A wheel notch while a close springs on the render server takes the camera: the close's landing
    /// neither ends the CPU's camera motion nor reports, and the daemon hears the column at rest once.
    @Test func aWheelNotchDuringACloseReportsOnceAtTheColumnItLandsOn() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(5), focused: "p5")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.root.driver.isManual = true
            fixture.screen.discreteScroll(direction: -1)
            fixture.close(to: ColumnCloseScrollMotionTests.columns(4), focus: "p4")
            try #require(fixture.screen.renderClose?.reportsLeadingColumn == true, "the render-server close does not own the report")
            fixture.screen.discreteScroll(direction: -1)
            #expect(fixture.screen.renderClose == nil, "the close in flight kept the camera from the wheel")
            #expect(!fixture.screen.scrollRidesFrames, "the wheel's camera rides the close spring")
            #expect(fixture.stepToRest(), "the wheel's camera did not land")
            #expect(await fixture.renderSpringsDrained(), "the close did not land in 5 s")
            let expected = try #require(fixture.restingLeadingColumn)
            #expect(fixture.reported == [expected], "reported \(fixture.reported), not once the resting column \(expected)")
        }
    }

    /// A close the CPU steps (the switch off for it) while a render-server close is in flight: the earlier
    /// close's landing leaves the camera on the CPU close's spring (one curve, Lawrence 2026-10-20).
    @Test func aCPUCloseDuringARenderCloseKeepsItsCameraSpring() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(4), focused: "p4")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.root.driver.isManual = true
            fixture.close(to: ColumnCloseScrollMotionTests.columns(3), focus: "p3")
            try #require(fixture.screen.renderSpringsInFlight > 0, "the first close is not on the render server")
            fixture.renderServer.isOn = false
            fixture.close(to: ColumnCloseScrollMotionTests.columns(2), focus: "p2")
            #expect(fixture.screen.hasMotion, "the second close does not step on the CPU")
            #expect(await fixture.renderSpringsDrained(), "the first close's springs did not end")
            #expect(fixture.screen.scrollRidesFrames, "the first close's landing took the camera off the close spring")
            #expect(fixture.screen.hasMotion, "the first close's landing ended the CPU close")
            #expect(fixture.stepToRest(), "the CPU close did not land")
            #expect(fixture.reported.count <= 1, "the leading column went out \(fixture.reported.count) times")
        }
    }

    /// Cmd-W twice on three columns: the second close removes the column edge the first one still springs.
    /// Its springs end with the handle, so the motion lands once and nothing stays counted in flight.
    @Test func aCloseDuringACloseLands() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(3), focused: "p3")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.close(to: ColumnCloseScrollMotionTests.columns(2), focus: "p2")
            let edges = Set(fixture.screen.dividerViews.keys)
            fixture.close(to: ColumnCloseScrollMotionTests.columns(1), focus: "p1")
            try #require(!edges.isSubset(of: Set(fixture.screen.dividerViews.keys)), "the second close removed no handle")
            #expect(await fixture.landed(), "the closes did not land in 5 s")
            #expect(fixture.motion == [true, false], "layout motion \(fixture.motion)")
            #expect(fixture.screen.renderSpringsInFlight == 0, "\(fixture.screen.renderSpringsInFlight) springs never landed")
            #expect(!fixture.screen.userMotionActive, "the layout still counts as moving")
        }
    }

    /// Closing the focused bottom row of a scrolling row column: the row camera rests in the model and its
    /// shift rides each pane's own spring, from where it showed.
    @Test func closingTheLastRowShiftsTheRowCameraOnTheFrameSpring() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.rows([750, 750, 750]), focused: "p3")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            try #require(fixture.screen.rowOffset(of: "p3") > 100, "three tall rows scroll down to p3")
            let clock = try #require(fixture.root.layer)
            let before = try Self.layer(fixture, "p2").frame
            Render.freeze(clock)
            fixture.close(to: ColumnCloseScrollMotionTests.rows([750, 750]), focus: "p2")
            try Self.expectAtRest(fixture, ["p1", "p2"])
            #expect(!fixture.screen.rowsMoving, "the row camera still springs on the CPU")
            let layer = try Self.layer(fixture, "p2")
            let from = try Render.presented(layer, at: 0, root: clock)
            #expect(Render.gap(from, before) <= 0.5, "p2 jumped from \(before) to \(from) in the close's turn")
            #expect(Render.gap(from, layer.frame) > 100, "p2 does not move with the row camera: \(from) to \(layer.frame)")
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(fixture.screen.motionState.frameSpring))
            let shown = try Render.presented(layer, at: half, root: clock)
            let expected = Render.midpoint(from, layer.frame)
            #expect(Render.gap(shown, expected) <= 1, "p2 shows \(shown) half way, not \(expected)")
        }
    }

    /// The focus a close lands moves the camera in its own turn while the close's springs are part way:
    /// the retarget adds springs from where each pane shows, so nothing jumps.
    @Test func aCameraRetargetMidCloseStartsFromWhatShows() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(4), focused: "p4")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.apply(ColumnCloseScrollMotionTests.columns(3))
            try #require(fixture.screen.renderSpringsInFlight > 0, "the close is not on the render server")
            let target = fixture.screen.scroll.target
            let part = Render.time(toProgress: 0.3, Motion.panes.spring(fixture.screen.motionState.frameSpring))
            let layer = try Self.layer(fixture, "p2")
            let mid = try Render.presented(layer, at: part, root: clock)
            fixture.focus("p1")
            try #require(abs(fixture.screen.scroll.target - target) > 50, "focusing p1 does not move the camera")
            try Self.expectAtRest(fixture, ["p1", "p2", "p3"])
            let after = try Render.presented(layer, at: part, root: clock)
            #expect(Render.gap(mid, after) <= 0.5, "p2 jumped from \(mid) to \(after) when the camera retargeted")
        }
    }

    /// Cmd-W while the camera still springs (a center): the panes it carries keep its velocity, so the
    /// motion does not stop and start again where the render server takes it.
    @Test func aCloseKeepsTheCamerasVelocity() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(4), focused: "p4")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.root.driver.isManual = true
            fixture.screen.center("p1", animated: true)
            for _ in 0..<4 { _ = fixture.root.advanceFrame(1.0 / 120) }
            let camera = fixture.screen.scroll.velocity
            try #require(abs(camera) > 200, "the camera does not move (\(camera) pt/s)")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.close(to: ColumnCloseScrollMotionTests.columns(3), focus: "p1")
            try #require(fixture.screen.renderSpringsInFlight > 0, "the close is not on the render server")
            let layer = try Self.layer(fixture, "p1")
            let step = 0.0002
            let start = try Render.presented(layer, at: 0, root: clock), next = try Render.presented(layer, at: step, root: clock)
            let velocity = (next.minX - start.minX) / step
            #expect(abs(velocity + camera) <= abs(camera) * 0.1 + 30,
                    "p1 starts at \(velocity) pt/s on the render server, the camera moved it at \(-camera) pt/s")
        }
    }

    /// A docked column's strip clip is placed at rest: until it is layer structure, a
    /// close beside a dock steps on the CPU, which clips every frame.
    @Test func aCloseBesideADockStepsOnTheCPU() async throws {
        try await Render.withMotion {
            let layout = ScreenLayout.columns(ColumnCloseScrollMotionTests.columns(3).columns + [
                LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
            ])
            let remaining = ScreenLayout.columns(ColumnCloseScrollMotionTests.columns(2).columns + [
                LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
            ])
            let fixture = Screen(layout, focused: "p3")
            defer { fixture.close() }
            fixture.root.driver.isManual = true
            fixture.close(to: remaining, focus: "p2")
            #expect(fixture.screen.hasMotion, "the close beside a dock does not step on the CPU")
            #expect(fixture.screen.renderSpringsInFlight == 0, "the close beside a dock went to the render server")
            for pane: PaneID in ["p1", "p2"] {
                let keys = try fixture.host(pane).layer?.animationKeys() ?? []
                #expect(keys.isEmpty, "\(pane) has render-server springs beside a dock")
            }
        }
    }

    /// Movement off in the gate (Reduce Motion) while the layout still animates: the close lands in its turn.
    @Test func aCloseTheGateSnapsLandsInItsTurn() async throws {
        try await Render.withMotion(reduceMotion: true) {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(3), focused: "p3", reduceMotion: false)
            defer { fixture.close() }
            fixture.screen.reportScrollOnSettle = true
            fixture.close(to: ColumnCloseScrollMotionTests.columns(2), focus: "p2")
            try Self.expectAtRest(fixture, ["p1", "p2"])
            #expect(fixture.motion.last != true, "the close did not land in its turn: \(fixture.motion)")
            #expect(fixture.reported.count == 1, "the leading column went out \(fixture.reported.count) times")
            #expect(fixture.screen.renderSpringsInFlight == 0)
            for pane: PaneID in ["p1", "p2"] {
                let host = try fixture.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring)
                #expect(host.layer?.animationKeys()?.isEmpty ?? true, "\(pane) animates with movement off")
            }
        }
    }

    @Test func offTheCloseStepsOnTheCPUAsBefore() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(3), focused: "p3", renderServer: false)
            defer { fixture.close() }
            fixture.root.driver.isManual = true
            fixture.close(to: ColumnCloseScrollMotionTests.columns(2), focus: "p2")
            #expect(fixture.screen.hasMotion, "the close does not spring on the CPU")
            #expect(fixture.screen.scrollRidesFrames, "the camera does not ride the close spring")
            #expect(fixture.screen.renderSpringsInFlight == 0)
            for pane: PaneID in ["p1", "p2"] {
                let keys = try fixture.host(pane).layer?.animationKeys() ?? []
                #expect(keys.isEmpty, "\(pane) has render-server springs with the switch off")
            }
            #expect(fixture.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
        }
    }
}
