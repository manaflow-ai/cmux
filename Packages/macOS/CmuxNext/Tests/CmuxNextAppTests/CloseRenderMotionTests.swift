import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A close on the render server (chrome-parity p03-rendering-022b, `motion.renderServer` on): Cmd-W on
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

    /// One screen `s` in a 1200 x 800 window, with what the root announced and reported.
    final class Screen {
        let panes = SplitRenderMotionTests.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Every layout motion start (true) and end (false) the root announced.
        var motion: [Bool] = []
        /// Every leading column the screen reported to the daemon (`LayoutIntent.scrollTo`).
        var reported: [ColumnID] = []
        private var observation: LayoutOverlaySyncObservation?
        private var landing: CheckedContinuation<Bool, Never>?

        init(_ layout: ScreenLayout, focused: PaneID, renderServer: Bool = true, reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
            model.rowsEnabledOverride = true
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer })
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

    /// A close lands once: one motion start and one end, nothing left on a spring, no frames asked, and a
    /// leading-column report the camera owed (a wheel notch's) goes out then, not in the close's turn.
    @Test func theCloseLandsOnceAndReportsTheLeadingColumnThen() async throws {
        try await Render.withMotion {
            let fixture = Screen(ColumnCloseScrollMotionTests.columns(4), focused: "p4")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.screen.reportScrollOnSettle = true
            fixture.close(to: ColumnCloseScrollMotionTests.columns(3), focus: "p3")
            #expect(fixture.reported.isEmpty, "the leading column went out before the camera landed: \(fixture.reported)")
            #expect(!fixture.screen.reportScrollOnSettle, "the report waits for a CPU camera frame")
            #expect(await fixture.landed(), "the close did not land in 5 s")
            #expect(fixture.motion == [true, false], "layout motion \(fixture.motion)")
            #expect(fixture.reported.count == 1, "the leading column went out \(fixture.reported.count) times")
            #expect(fixture.screen.renderSpringsInFlight == 0)
            #expect(!fixture.screen.scrollRidesFrames, "the camera still rides a landed close")
            #expect(!fixture.root.driver.isRunning, "the landing asked for layout frames")
            for pane: PaneID in ["p1", "p2", "p3"] {
                let host = try fixture.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring, "\(pane) is still on its spring")
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
