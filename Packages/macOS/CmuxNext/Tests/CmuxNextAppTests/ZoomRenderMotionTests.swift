import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import CmuxNextWakeups
import Testing

/// A zoom on the render server (`motion.renderServer` on): Cmd-Shift-Enter
/// puts the zooming pane at its rest frame in the key's turn and Core Animation shows it springing there on
/// the zoom token. No CPU spring steps, the panes it covers stay untouched under it, it stays above them
/// until it lands, and the landing restores the stacking and lets the covered panes go once.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct ZoomRenderMotionTests {
    typealias Render = SplitRenderMotionTests

    /// p1 p2 / p3 p4.
    static let grid: SplitNode = .split("v", axis: .vertical, ratio: 0.5,
                                        a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                        b: .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))
    static let others: [PaneID] = ["p2", "p3", "p4"]
    /// A docked chat column on the left, then p1 and p2 in the strip.
    static let docked = ScreenLayout.columns([
        LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .left, mode: .docked)),
        LayoutColumn(id: "c1", width: 0.3, root: .leaf("p1")),
        LayoutColumn(id: "c2", width: 0.3, root: .leaf("p2")),
    ])

    /// A view in a pane that draws in its own child window (a Chromium page), or in the layer tree.
    final class Page: NSView, ChildWindowContent {
        var drawsInChildWindow = true
    }

    /// `layout` (the 2 x 2 grid) in a 1200 x 800 window; ``zoom(_:)`` and ``unzoom()`` are Cmd-Shift-Enter.
    final class Grid {
        let panes = SplitRenderMotionTests.Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let layout: ScreenLayout
        /// Every layout motion start (true) and end (false) the root announced.
        var motion: [Bool] = []
        /// Runs inside the root's announcement that the layout motion ended.
        var onLanding: (() -> Void)?
        private var observation: LayoutOverlaySyncObservation?
        private var landing: CheckedContinuation<Bool, Never>?

        init(renderServer: Bool, reduceMotion: Bool = false, layout: ScreenLayout = .splits(ZoomRenderMotionTests.grid)) {
            self.layout = layout
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            observation = root.observeLayoutMotion { [weak self] moving in
                guard let self else { return }
                motion.append(moving)
                if !moving {
                    onLanding?()
                    resumeLanding(true)
                }
            }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func host(_ pane: PaneID) throws -> PaneHostView { try #require(root.context.hosts[pane]) }

        func zoom(_ pane: PaneID = "p1") {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(pane)), zoomed: true)])
            root.syncWithModel()
        }

        func unzoom() {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
        }

        /// The rects that hide `host`'s ring and dim now, in the screen's coordinates.
        func ringCovers(_ host: PaneHostView) -> [CGRect] {
            screen.ringCovers(of: host, docks: screen.coverRects, above: screen.panesAbove())
        }

        /// The host that draws in front of every other pane host of the screen.
        var frontHost: PaneHostView? { screen.stackedSubviews.last { $0 is PaneHostView } as? PaneHostView }

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

    @Test func aZoomRestsInTheKeysTurnAndSpringsOnTheRenderServerOverTheUntouchedPanes() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(grid.root.layer)
            let still = try Dictionary(uniqueKeysWithValues: Self.others.map { ($0, try grid.host($0).frame) })
            Render.freeze(clock)
            grid.zoom()
            let screen = grid.screen
            let host = try grid.host("p1")
            #expect(!screen.hasMotion, "a CPU spring is left to step")
            #expect(!grid.root.driver.isRunning, "the zoom asked the window's MotionClock for layout frames")
            #expect(grid.motion == [true], "the layout motion starts in the key's turn")
            #expect(screen.zoomMotion.pane == "p1" && screen.zoomMotion.rendersOnServer, "the zoom is not on the render server")
            #expect(host.frame == screen.geometry.panes["p1"]?.pixelEdges(screen.scale), "p1 is not at rest after the key's turn")
            #expect(host.isOnRenderSpring && host.isOnLayoutSpring && host.backsZoom)
            #expect(grid.frontHost === host, "the zooming pane is not in front of the panes it covers")
            #expect(Set(screen.covered) == Set(Self.others), "covered \(screen.covered)")
            // Half way along the zoom token's spring, p1 shows half way between where it showed and its rest.
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(screen.zoomMotion.spring(for: "p1")))
            let layer = try #require(host.layer)
            let from = try Render.presented(layer, at: 0, root: clock)
            let shown = try Render.presented(layer, at: half, root: clock)
            #expect(Render.gap(from, layer.frame) > 100, "p1 does not move: \(from) to \(layer.frame)")
            let expected = Render.midpoint(from, layer.frame)
            #expect(Render.gap(shown, expected) <= 1, "p1 shows \(shown) half way, not \(expected)")
            // Covered: opaque, still, no spring of their own, in the window.
            for pane in Self.others {
                let other = try grid.host(pane)
                #expect(other.superview != nil && other.alphaValue == 1, "\(pane) left or faded under the zoom")
                #expect(other.frame == still[pane], "\(pane) moved under the zoom")
                #expect(other.layer?.animationKeys()?.isEmpty ?? true, "\(pane) springs under the zoom")
            }
        }
    }

    @Test func theZoomLandsOnceRestoresTheStackingAndLetsTheCoveredPanesGo() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            grid.zoom()
            let screen = grid.screen
            let covered = try Self.others.map { try grid.host($0) }
            // The motion's observers (and the interactive-rect report) see the covered panes gone, as on the CPU path.
            var attachedAtLanding: Int?
            grid.onLanding = { attachedAtLanding = covered.filter { $0.superview != nil }.count }
            #expect(await grid.landed(), "the zoom did not land in 5 s")
            #expect(attachedAtLanding == 0, "\(attachedAtLanding ?? -1) covered hosts were still in the screen when the motion ended")
            #expect(grid.motion == [true, false], "layout motion \(grid.motion)")
            #expect(screen.renderSpringsInFlight == 0)
            #expect(!grid.root.driver.isRunning, "the landing asked for layout frames")
            #expect(screen.zoomMotion.pane == nil && !screen.zoomMotion.rendersOnServer, "the zoom still owns the motion")
            #expect(screen.covered.isEmpty, "the covered panes were not let go")
            #expect(covered.allSatisfy { $0.superview == nil }, "a covered host stays in the screen")
            let host = try grid.host("p1")
            #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring && !host.backsZoom)
            #expect(!screen.stripContainer.isLifted, "the strip container is still lifted")
            let settled = grid.panes.contents["p1"]?.settled ?? 0
            #expect(settled == 1, "p1's content heard \(settled) landings")
        }
    }

    @Test func anUnzoomSpringsBackOverTheReturningPanesAndRestoresTheStacking() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            grid.zoom()
            #expect(await grid.landed(), "the zoom did not land in 5 s")
            grid.motion = []
            grid.unzoom()
            let screen = grid.screen
            let host = try grid.host("p1")
            #expect(!screen.hasMotion, "a CPU spring is left to step")
            #expect(screen.zoomMotion.pane == "p1" && screen.zoomMotion.rendersOnServer, "the unzoom is not on the render server")
            #expect(host.frame == screen.geometry.panes["p1"]?.pixelEdges(screen.scale), "p1 is not at its slot after the key's turn")
            #expect(grid.frontHost === host, "the unzooming pane is not in front of the returning panes")
            for pane in Self.others {
                let other = try grid.host(pane)
                #expect(other.frame == screen.geometry.panes[pane]?.pixelEdges(screen.scale), "\(pane) does not return at rest")
                #expect(other.layer?.animationKeys()?.isEmpty ?? true, "\(pane) springs as it returns")
            }
            #expect(await grid.landed(), "the unzoom did not land in 5 s")
            #expect(grid.motion == [true, false], "layout motion \(grid.motion)")
            #expect(screen.zoomMotion.pane == nil && !host.backsZoom && !screen.stripContainer.isLifted, "the stacking is not restored")
        }
    }

    /// Cmd-Shift-Enter again half way: the unzoom starts from what shows, at the zoom's velocity.
    @Test func anUnzoomMidZoomRetargetsFromWhatShows() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(grid.root.layer)
            Render.freeze(clock)
            grid.zoom()
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(grid.screen.zoomMotion.spring(for: "p1")))
            let layer = try #require(try grid.host("p1").layer)
            let before = try Render.presented(layer, at: half, root: clock)
            grid.unzoom()
            #expect(!grid.screen.hasMotion, "the retarget left a CPU spring to step")
            #expect(grid.screen.zoomMotion.rendersOnServer, "the retarget left the render server")
            let after = try Render.presented(layer, at: half, root: clock)
            #expect(Render.gap(before, after) <= 0.5, "p1 jumped from \(before) to \(after) when the zoom retargeted")
        }
    }

    @Test func reduceMotionZoomsInTheKeysTurn() async throws {
        try await Render.withMotion(reduceMotion: true) {
            let grid = Grid(renderServer: true, reduceMotion: true)
            defer { grid.close() }
            grid.zoom()
            let screen = grid.screen
            #expect(!screen.hasMotion && screen.renderSpringsInFlight == 0 && screen.zoomMotion.pane == nil)
            let host = try grid.host("p1")
            #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring)
            #expect(host.layer?.animationKeys()?.isEmpty ?? true, "p1 animates under Reduce Motion")
            #expect(host.frame == screen.geometry.panes["p1"]?.pixelEdges(screen.scale))
        }
    }

    @Test func offTheZoomStepsOnTheCPUAsBefore() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: false)
            defer { grid.close() }
            grid.root.driver.isManual = true
            grid.zoom()
            let screen = grid.screen
            #expect(screen.hasMotion, "the zoom does not spring on the CPU")
            #expect(screen.zoomMotion.pane == "p1" && !screen.zoomMotion.rendersOnServer)
            #expect(screen.renderSpringsInFlight == 0)
            // Out of the #expect: a closure whose only `try` sits in a macro is inferred not to throw.
            let p1 = try grid.host("p1")
            #expect(p1.layer?.animationKeys()?.isEmpty ?? true, "p1 has render-server springs with the switch off")
            for _ in 0..<480 where !grid.root.advanceFrame(1.0 / 120) { break }
            #expect(!screen.hasMotion && screen.zoomMotion.pane == nil && screen.covered.isEmpty, "the CPU zoom did not land")
        }
    }
}
