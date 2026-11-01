import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
import QuartzCore
import Testing

/// A split on the render server (`motion.renderServer` on): Cmd-D
/// puts every pane it moves at its rest frame in the key's turn, its content told its rest size first,
/// and Core Animation shows the panes springing there from where they showed. No CPU spring steps, the
/// window's MotionClock never runs for it, the landing runs once, Reduce Motion lands in the turn, and
/// with the switch off the split steps on the CPU as before.
///
/// The windows are real and ordered in (a window on no screen does not animate), so the suite runs with
/// the pane bench (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct SplitRenderMotionTests {
    /// Pane content that records what its pane's layout spring tells it.
    final class Content: NSView, PaneMotionTargeting, PaneMotionSettling {
        var willRest: [CGSize] = []
        var settled = 0
        /// Every size the pane's layout gave the content.
        var sizes: [CGSize] = []

        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }

        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
            willRest.append(sizeChange)
            return .top
        }

        func paneMotionDidSettle() { settled += 1 }
    }

    final class Panes: LayoutPaneContentProvider {
        var contents: [PaneID: Content] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let content = Content()
            content.wantsLayer = true
            contents[pane] = content
            return content
        }
    }

    /// One pane `a` (or `layout`) in a 1200 x 800 window; ``split()`` is Cmd-D on `a`.
    final class Split {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// Every layout motion start (true) and end (false) the root announced.
        var motion: [Bool] = []
        private var observation: LayoutOverlaySyncObservation?
        private var landing: CheckedContinuation<Bool, Never>?

        init(renderServer: Bool, reduceMotion: Bool = false, layout: ScreenLayout = .splits(.leaf("a"))) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s",
                                focusedPane: "a")
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
                if !moving { resumeLanding(true) }
            }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func host(_ pane: PaneID) throws -> PaneHostView { try #require(root.context.hosts[pane]) }

        /// The daemon's tree after Cmd-D on `pane` (a new pane `added` on its right), in the key's turn.
        func split(_ tree: SplitNode) { split(.splits(tree)) }

        /// The daemon's `layout` after a split, with the focus on `focus` when given, in one turn.
        func split(_ layout: ScreenLayout, focus: PaneID? = nil) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            if let focus { model.focus(focus, notify: false, source: .keyboard) }
            root.syncWithModel()
        }

        /// Cmd-D on `a`.
        func split() { split(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))) }

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

    /// Movement animates for the panes gate (Reduce Motion pinned to `reduceMotion`).
    static func withMotion<T>(reduceMotion: Bool = false, _ body: () async throws -> T) async throws -> T {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesMovement != reduceMotion, "panes movement does not follow Reduce Motion on this host")
        return try await body()
    }

    /// Stops the render server's clock under `root`: springs show the time ``seek(_:to:)`` sets.
    static func freeze(_ root: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.speed = 0
        root.timeOffset = 0
        CATransaction.commit()
        CATransaction.flush()
    }

    static func seek(_ root: CALayer, to time: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.timeOffset = time
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The frame `layer` presents (its superlayer's coordinates) `time` seconds into the frozen clock.
    static func presented(_ layer: CALayer, at time: CFTimeInterval, root: CALayer) throws -> CGRect {
        seek(root, to: time)
        return try #require(layer.presentation(), "no presentation layer after a commit").frame
    }

    /// Seconds a spring from rest takes to cover `progress` of its way (cmux-motion's closed form, which the
    /// render-server spring matches within 0.25 pt, RenderSpringParityTests). Solved to a microsecond: a
    /// coarser step overshoots, and near half way a split spring covers about 9 times its travel per
    /// second, so a 0.5 ms step put the sample 0.23 % past the midpoint, 1.35 pt on a 600 pt move.
    static func time(toProgress progress: Double, _ spring: SpringParameters) -> Double {
        func covered(_ time: Double) -> Double {
            1 - SpringValue.solve(displacement: 1, velocity: 0, time: time, parameters: spring).displacement
        }
        // Before the first time it covers `progress` (an underdamped spring passes it more than once).
        var high = 0.0
        while high < 5, covered(high) < progress { high += 0.001 }
        var low = max(0, high - 0.001)
        while high - low > 1e-6 {
            let mid = (low + high) / 2
            if covered(mid) < progress { low = mid } else { high = mid }
        }
        return high
    }

    /// Waits until `condition` holds, checking every 10 ms (the render server's landings come on the run
    /// loop, with no observer to await); false after `timeout`.
    static func until(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The largest gap between two rects' edges and sizes.
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    static func midpoint(_ a: CGRect, _ b: CGRect) -> CGRect {
        CGRect(x: (a.minX + b.minX) / 2, y: (a.minY + b.minY) / 2, width: (a.width + b.width) / 2, height: (a.height + b.height) / 2)
    }

    @Test func aSplitRestsInTheKeysTurnAndSpringsOnTheRenderServer() async throws {
        try await Self.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            Self.freeze(clock)
            split.split()
            let screen = split.screen
            #expect(!screen.hasMotion, "a CPU spring is left to step")
            #expect(!split.root.driver.isRunning, "the split asked the window's MotionClock for layout frames")
            #expect(split.motion == [true], "the layout motion starts in the key's turn")
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                let frame = try #require(screen.paneFrames[pane])
                #expect(host.frame == frame.targetRect.pixelEdges(screen.scale), "\(pane) is not at rest after the key's turn")
                #expect(host.content.frame.size == host.contentRect.size, "\(pane)'s content is not at its rest size")
                #expect(host.isOnRenderSpring && host.isOnLayoutSpring, "\(pane) is not on its spring")
                let content = try #require(split.panes.contents[pane])
                #expect(content.willRest.count == 1, "\(pane)'s content heard its rest size \(content.willRest.count) times")
                #expect(content.settled == 0, "\(pane) landed in the key's turn")
            }
            // Half way along the spring, each pane shows half way between where it showed and its rest.
            let half = Self.time(toProgress: 0.5, Motion.panes.spring(screen.motionState.frameSpring))
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                let layer = try #require(host.layer)
                let from = try Self.presented(layer, at: 0, root: clock)
                let shown = try Self.presented(layer, at: half, root: clock)
                #expect(Self.gap(from, layer.frame) > 100, "\(pane) does not move: \(from) to \(layer.frame)")
                let expected = Self.midpoint(from, layer.frame)
                #expect(Self.gap(shown, expected) <= 1, "\(pane) shows \(shown) half way, not \(expected)")
            }
        }
    }

    @Test func aSecondSplitWhileSpringingRetargetsFromWhatShows() async throws {
        try await Self.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(split.root.layer)
            Self.freeze(clock)
            split.split()
            let half = Self.time(toProgress: 0.5, Motion.panes.spring(split.screen.motionState.frameSpring))
            let springing = try split.host("b")
            let layer = try #require(springing.layer)
            let before = try Self.presented(layer, at: half, root: clock)
            // Cmd-D on b half way: b gives half its rest to c.
            split.split(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                               b: .split(SplitID("e"), axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
            #expect(!split.screen.hasMotion, "the retarget left a CPU spring to step")
            let after = try Self.presented(layer, at: half, root: clock)
            #expect(Self.gap(before, after) <= 0.5, "b jumped from \(before) to \(after) when the split retargeted")
            let added = try split.host("c")
            #expect(added.isOnRenderSpring, "the second split's new pane is not on the render server")
        }
    }

    /// The frame is set once, to rest: the content resizes once, to its rest size, never to where the pane
    /// starts (a split's new pane starts as a sliver).
    @Test func eachContentResizesOnceToItsRest() async throws {
        try await Self.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            Self.freeze(try #require(split.root.layer))
            let before = split.panes.contents["a"]?.sizes.count ?? 0
            split.split()
            for pane: PaneID in ["a", "b"] {
                let content = try #require(split.panes.contents[pane])
                let sizes = pane == "a" ? Array(content.sizes.dropFirst(before)) : content.sizes
                let host = try split.host(pane)
                #expect(sizes == [host.contentRect.size], "\(pane)'s content took \(sizes) in the key's turn, not its rest once")
            }
        }
    }

    /// A zoom before the split lands: the split's render-server springs come back to the CPU frames and the
    /// zoom takes the zooming pane on from what shows, on the render server too; its
    /// content hears one landing, when the zoom lands.
    @Test func aZoomBeforeTheSplitLandsSettlesOnceWhenTheZoomLands() async throws {
        try await Self.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            split.split()
            try #require(split.screen.renderSpringsInFlight > 0, "the split is not on the render server")
            split.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("b")), zoomed: true)])
            split.root.syncWithModel()
            #expect(!split.screen.hasMotion, "the zoom left a CPU spring to step")
            #expect(split.screen.zoomMotion.rendersOnServer, "the zoom is not on the render server")
            let content = try #require(split.panes.contents["b"])
            #expect(content.settled == 0, "b heard a landing in the zoom's turn")
            #expect(try split.host("b").isOnLayoutSpring, "b left its layout spring mid-zoom")
            #expect(await split.landed(), "the zoom did not land in 5 s")
            #expect(split.screen.zoomMotion.pane == nil, "the zoom still owns the motion")
            #expect(content.settled == 1, "b heard \(content.settled) landings")
        }
    }

    @Test func theSplitLandsOnce() async throws {
        try await Self.withMotion {
            let split = Split(renderServer: true)
            defer { split.close() }
            try #require(split.window.screen != nil, "the window is on no screen: nothing animates")
            split.split()
            #expect(await split.landed(), "the split did not land in 5 s")
            #expect(split.motion == [true, false], "layout motion \(split.motion)")
            #expect(split.screen.renderSpringsInFlight == 0)
            #expect(!split.root.driver.isRunning, "the landing asked for layout frames")
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring, "\(pane) is still on its spring")
                let settled = split.panes.contents[pane]?.settled ?? 0
                #expect(settled == 1, "\(pane)'s content heard \(settled) landings")
            }
        }
    }

    @Test func reduceMotionLandsInTheKeysTurn() async throws {
        try await Self.withMotion(reduceMotion: true) {
            let split = Split(renderServer: true, reduceMotion: true)
            defer { split.close() }
            split.split()
            #expect(!split.screen.hasMotion)
            #expect(split.screen.renderSpringsInFlight == 0)
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(!host.isOnRenderSpring && !host.isOnLayoutSpring)
                #expect(host.layer?.animationKeys()?.isEmpty ?? true, "\(pane) animates under Reduce Motion")
                #expect(host.frame == split.screen.paneFrames[pane]?.targetRect.pixelEdges(split.screen.scale))
            }
        }
    }

    @Test func offTheSplitStepsOnTheCPUAsBefore() async throws {
        try await Self.withMotion {
            let split = Split(renderServer: false)
            defer { split.close() }
            split.root.driver.isManual = true
            split.split()
            #expect(split.screen.hasMotion, "the split does not spring on the CPU")
            #expect(split.screen.renderSpringsInFlight == 0)
            for pane: PaneID in ["a", "b"] {
                let host = try split.host(pane)
                #expect(!host.isOnRenderSpring)
                #expect(host.layer?.animationKeys()?.isEmpty ?? true, "\(pane) has render-server springs with the switch off")
            }
            #expect(split.root.advanceFrame(1.0 / 120), "the CPU step has nothing to move")
        }
    }
}
