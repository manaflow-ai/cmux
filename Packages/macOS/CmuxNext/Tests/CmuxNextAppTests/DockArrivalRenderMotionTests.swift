import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A new dock column on the render server (`motion.renderServer` on): the
/// docked pane grows in from its screen edge on its host's render-server spring, the strip's panes spring
/// aside, and the strip's clip (the strip container's bounds) springs with the dock on
/// the same token, from the range beside the dock's sliver to its rest. Every frame is at rest after the
/// change's turn, no CPU spring steps and the window's MotionClock never runs: 0 steps per frame. The strip
/// range is computed at plan apply only (`PaneArrival.stripClip`), never per frame.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct DockArrivalRenderMotionTests {
    typealias Render = SplitRenderMotionTests
    typealias Screen = CloseRenderMotionTests.Screen

    /// Two strip columns filling the screen.
    static let strip = ColumnCloseScrollMotionTests.columns(2)

    /// The same strip with a new docked column on the right holding the new pane `chat`.
    static let docked = ScreenLayout.columns(strip.columns + [
        LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
    ])

    /// The docked layout with the strip's two columns traded: a structural change that adds and removes no pane,
    /// as a second press or the daemon's echo while the dock still grows in.
    static let traded = ScreenLayout.columns([
        LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2")),
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
        LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
    ])

    /// The strip's rest range beside the docks.
    static func restRange(_ fixture: Screen) throws -> CGRect {
        try #require(PaneArrival.stripClip(fixture.screen.geometry, docks: []), "the docked layout has no strip range")
    }

    /// The left edge and width `host` shows at in the screen, `time` seconds into the frozen clock: its
    /// presented frame inside the strip container's presented bounds, placed at the container's presented frame.
    static func shownX(_ host: PaneHostView, in container: NSView, at time: CFTimeInterval, root: CALayer) throws -> (minX: CGFloat, width: CGFloat) {
        Render.seek(root, to: time)
        let hostLayer = try #require(host.layer?.presentation(), "no presentation layer for the host")
        let clip = try #require(container.layer?.presentation(), "no presentation layer for the strip container")
        return (clip.frame.minX + hostLayer.frame.minX - clip.bounds.minX, hostLayer.frame.width)
    }

    @Test func aNewDockGrowsInOnTheRenderServerWithItsStripClip() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.strip, focused: "p2")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let before = try fixture.host("p2").frame
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.apply(Self.docked)
            let screen = fixture.screen, container = screen.stripContainer
            #expect(!screen.hasMotion, "a CPU spring is left to step for the new dock")
            #expect(!fixture.root.driver.isRunning, "the new dock asked the window's MotionClock for layout frames")
            #expect(screen.renderSpringsInFlight > 0, "the new dock is not on the render server")
            let chat = try fixture.host("chat")
            #expect(chat.isOnRenderSpring, "the dock's pane is not on its render-server spring")
            #expect(chat.frame == screen.paneFrames["chat"]?.targetRect.pixelEdges(screen.scale), "the dock's pane is not at rest")
            let rest = try Self.restRange(fixture)
            #expect(container.frame == rest, "the strip container is at \(container.frame), not its rest range \(rest)")
            let clip = try #require(container.layer)
            #expect(!(clip.animationKeys() ?? []).isEmpty, "the strip's clip does not spring with the dock")

            // At the start the strip reaches the dock's sliver at the screen edge: it is not cut at the rest edge.
            let start = try Render.presented(clip, at: 0, root: clock)
            #expect(start.maxX - rest.maxX > 100, "the strip starts cut at \(start.maxX), the dock's rest edge is \(rest.maxX)")
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(screen.motionState.frameSpring))
            let shown = try Render.presented(clip, at: half, root: clock)
            let expected = Render.midpoint(start, clip.frame)
            #expect(Render.gap(shown, expected) <= 1, "the strip's clip shows \(shown) half way, not \(expected)")

            // The clip's bounds and position move together: a strip pane shows only its own spring, from where it showed.
            let p2 = try fixture.host("p2")
            let first = try Self.shownX(p2, in: container, at: 0, root: clock)
            #expect(abs(first.minX - before.minX) <= 1 && abs(first.width - before.width) <= 1,
                    "p2 starts at x \(first.minX) w \(first.width), it showed at \(before)")
            let middle = try Self.shownX(p2, in: container, at: half, root: clock)
            let mid = (minX: (before.minX + p2.frame.minX) / 2, width: (before.width + p2.frame.width) / 2)
            #expect(abs(middle.minX - mid.minX) <= 1 && abs(middle.width - mid.width) <= 1,
                    "p2 shows at x \(middle.minX) w \(middle.width) half way, not \(mid)")
        }
    }

    /// `PaneArrival.stripClip` runs at plan apply only: CPU presentations while the dock grows on the render
    /// server (what a wheel notch or a scrollbar frame runs) and the landing compute no strip range.
    @Test func theStripRangeIsComputedAtPlanApplyOnly() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.strip, focused: "p2")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.apply(Self.docked)
            let screen = fixture.screen
            let planned = screen.stripRangesComputed
            #expect(screen.renderSpringsInFlight > 0, "the new dock is not on the render server")
            for _ in 0..<5 { screen.applyPresentation() }
            #expect(screen.stripRangesComputed == planned,
                    "CPU presentations during the dock's spring computed \(screen.stripRangesComputed - planned) strip ranges")
            #expect(await fixture.landed(), "the new dock did not land in 5 s")
            #expect(screen.stripRangesComputed == planned,
                    "the dock's spring computed \(screen.stripRangesComputed - planned) strip ranges before it landed")
        }
    }

    /// A structural change while the dock still grows in takes the springs back and restarts them from what
    /// shows: the strip's clip restarts too, from the range beside the dock where it shows and at its speed, so
    /// the strip still reaches the dock's moving edge and no background shows between them.
    @Test func aChangeWhileTheDockGrowsKeepsTheClipAtTheDocksEdge() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.strip, focused: "p2")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.apply(Self.docked)
            let screen = fixture.screen
            let early = Render.time(toProgress: 0.3, Motion.panes.spring(screen.motionState.frameSpring))
            Render.seek(clock, to: early)
            fixture.apply(Self.traded)
            #expect(!screen.hasMotion, "the change left a CPU spring to step")
            #expect(screen.renderSpringsInFlight > 0, "the change is not on the render server")
            let dock = try #require(fixture.host("chat").layer), clip = try #require(screen.stripContainer.layer)
            #expect(!(clip.animationKeys() ?? []).isEmpty, "the strip's clip stopped springing with the dock still growing in")
            for time in [early, early + 0.03, early + 0.1, early + 0.2] {
                let shownDock = try Render.presented(dock, at: time, root: clock)
                let shownClip = try Render.presented(clip, at: time, root: clock)
                // How far each edge still is from its rest: the strip's edge rides the dock's.
                let dockShort = shownDock.minX - dock.frame.minX, clipShort = shownClip.maxX - clip.frame.maxX
                #expect(abs(dockShort - clipShort) <= 1,
                        "at \(time) s the dock's edge is \(dockShort) pt from its rest, the strip's clip \(clipShort) pt")
                if time == early { #expect(dockShort > 20, "the dock is not still growing in when the change lands") }
            }
        }
    }

    @Test func theNewDockLandsOnceAtRest() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.strip, focused: "p2")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.apply(Self.docked)
            #expect(await fixture.landed(), "the new dock did not land in 5 s")
            #expect(fixture.motion == [true, false], "layout motion \(fixture.motion)")
            let screen = fixture.screen
            #expect(screen.renderSpringsInFlight == 0)
            #expect(screen.renderTracks.isEmpty, "a render-server track outlived the landing")
            let rest = try Self.restRange(fixture)
            #expect(screen.stripContainer.frame == rest, "the strip's clip landed at \(screen.stripContainer.frame), not \(rest)")
            #expect(screen.stripContainer.layer?.animationKeys()?.isEmpty ?? true, "the strip's clip still springs")
            #expect(!fixture.root.driver.isRunning, "the landing asked for layout frames")
            for pane: PaneID in ["p1", "p2", "chat"] {
                let host = try fixture.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring, "\(pane) is still on its spring")
            }
        }
    }

    /// A split in the strip beside a dock that is at rest moves no clip: the container keeps its range and
    /// gets no spring, and the split still goes to the render server.
    @Test func aSplitBesideARestingDockLeavesTheClipStill() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.docked, focused: "p2")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.root.driver.isManual = true
            _ = fixture.stepToRest()
            let range = fixture.screen.stripContainer.frame
            fixture.apply(.columns([
                LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                LayoutColumn(id: "c2", width: 0.5, root: .split(SplitID("d"), axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
                LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
            ]))
            let screen = fixture.screen
            #expect(screen.renderSpringsInFlight > 0, "the split beside a dock is not on the render server")
            #expect(!screen.hasMotion, "the split beside a dock left a CPU spring to step")
            #expect(screen.stripContainer.frame == range, "the split moved the strip's clip")
            #expect(screen.stripContainer.layer?.animationKeys()?.isEmpty ?? true, "the strip's clip springs for a split")
        }
    }

    @Test func offTheNewDockStepsOnTheCPUAsBefore() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.strip, focused: "p2", renderServer: false)
            defer { fixture.close() }
            fixture.root.driver.isManual = true
            fixture.apply(Self.docked)
            let screen = fixture.screen
            #expect(screen.hasMotion, "the new dock does not spring on the CPU")
            #expect(screen.renderSpringsInFlight == 0)
            // Out of the #expect: a closure whose only `try` sits in a macro is inferred not to throw.
            let chat = try fixture.host("chat")
            #expect(chat.layer?.animationKeys()?.isEmpty ?? true, "the dock springs on the render server with the switch off")
            #expect(screen.stripContainer.layer?.animationKeys()?.isEmpty ?? true, "the strip's clip springs on the render server with the switch off")
            let first = screen.stripContainer.frame
            #expect(fixture.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
            #expect(screen.stripContainer.frame != first, "the CPU step does not move the strip's clip with the growing dock")
        }
    }
}
