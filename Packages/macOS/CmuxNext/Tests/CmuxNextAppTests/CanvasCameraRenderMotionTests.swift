import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// The canvas camera's render-server springs as values: a hand-off from
/// the main thread follows the main thread's path, a retarget keeps value and velocity, a take-back hands
/// the main thread what shows, and the springs land on the target.
@Suite struct CanvasCameraRenderSpringTests {
    static let spring = SpringParameters(response: 0.35, dampingFraction: 0.9)
    /// Layer units per canvas point at zoom 1.25 on a flipped y axis.
    static let axes = RenderLayerAxes(x: 1.25, y: -1.25)
    static let from = CanvasCamera(center: CGPoint(x: 600, y: 400), zoom: 1)
    static let to = CanvasCamera(center: CGPoint(x: 900, y: 250), zoom: 1.25)

    /// A camera at `from` moving to `to`, handed to the render server at `time`.
    static func handedOff(at time: Double = 10) -> CanvasCameraMotion {
        var motion = CanvasCameraMotion()
        motion.retarget(from, animated: false)
        motion.retarget(to, animated: true)
        _ = motion.handToRenderServer(at: time, axes: axes, parameters: spring)
        return motion
    }

    @Test func aHandOffFollowsTheMainThreadsPath() {
        var cpu = CanvasCameraMotion()
        cpu.retarget(Self.from, animated: false)
        cpu.retarget(Self.to, animated: true)
        let motion = Self.handedOff()
        #expect(!motion.isMoving, "the main thread still steps the camera")
        #expect(motion.onRenderServer != nil)
        let start = motion.shown(at: 10)
        #expect(abs(start.center.x - 600) < 1e-9 && abs(start.center.y - 400) < 1e-9 && abs(start.zoom - 1) < 1e-12,
                "the hand-off does not start from what showed: \(start)")
        let dt = 1.0 / 120
        for frame in 1...30 {
            _ = cpu.advance(dt, parameters: Self.spring)
            let shown = motion.shown(at: 10 + Double(frame) * dt), stepped = cpu.shown
            #expect(abs(shown.center.x - stepped.center.x) < 0.01 && abs(shown.center.y - stepped.center.y) < 0.01,
                    "frame \(frame): the render server shows \(shown.center), the main thread \(stepped.center)")
            #expect(abs(shown.zoom - stepped.zoom) < 1e-4, "frame \(frame): zoom \(shown.zoom), main thread \(stepped.zoom)")
        }
    }

    @Test func theSpringsLandOnTheTarget() {
        let shown = Self.handedOff().shown(at: 20)
        #expect(abs(shown.center.x - Self.to.center.x) < 1e-6 && abs(shown.center.y - Self.to.center.y) < 1e-6)
        #expect(abs(shown.zoom - Self.to.zoom) < 1e-9)
        #expect(shown.centerRate == .zero && shown.zoomRate == 0)
    }

    @Test func aRetargetKeepsValueAndVelocity() {
        var motion = Self.handedOff()
        let time = 10.08
        let before = motion.shown(at: time)
        let next = CanvasCamera(center: CGPoint(x: 300, y: 700), zoom: 0.5)
        motion.retarget(next, animated: true)
        _ = motion.handToRenderServer(at: time, axes: RenderLayerAxes(x: 0.5, y: -0.5), parameters: Self.spring)
        let after = motion.shown(at: time)
        #expect(abs(after.center.x - before.center.x) < 1e-6 && abs(after.center.y - before.center.y) < 1e-6,
                "the center jumped from \(before.center) to \(after.center)")
        #expect(abs(after.zoom - before.zoom) < 1e-9, "the zoom jumped from \(before.zoom) to \(after.zoom)")
        #expect(abs(after.centerRate.x - before.centerRate.x) < 1e-6 && abs(after.centerRate.y - before.centerRate.y) < 1e-6,
                "the center's speed jumped from \(before.centerRate) to \(after.centerRate)")
        #expect(abs(after.zoomRate - before.zoomRate) < 1e-9, "the zoom's speed jumped from \(before.zoomRate) to \(after.zoomRate)")
        // The rate is the derivative of what shows (finite difference over 10 microseconds).
        let h = 0.00001, later = motion.shown(at: time + h)
        #expect(abs((later.zoom - after.zoom) / h - after.zoomRate) < 0.01 * max(1, abs(after.zoomRate)))
        #expect(abs((later.center.x - after.center.x) / h - after.centerRate.x) < 0.01 * max(1, abs(after.centerRate.x)))
        let landed = motion.shown(at: 30)
        #expect(abs(landed.center.x - 300) < 1e-6 && abs(landed.center.y - 700) < 1e-6 && abs(landed.zoom - 0.5) < 1e-9)
    }

    @Test func aTakeBackHandsTheMainThreadWhatShows() {
        var motion = Self.handedOff()
        let shown = motion.shown(at: 10.05)
        let tookBack = motion.takeBackFromRenderServer(at: 10.05)  // mutating: outside #expect, which reads a copy
        #expect(tookBack)
        #expect(motion.onRenderServer == nil)
        #expect(motion.state == shown, "the main thread starts from \(motion.state), not \(shown)")
        #expect(motion.isMoving && motion.target == Self.to)
        let tookBackAgain = motion.takeBackFromRenderServer(at: 10.06)
        #expect(!tookBackAgain, "a second take-back found springs")
    }

    /// A click took the move back (the main thread steps it, zoom still moving); the next change hands it over
    /// again: the render server starts at the main thread's zoom speed and follows its path, with no stop.
    @Test func aMovingMainThreadCameraHandsOverAtItsSpeed() {
        var motion = Self.handedOff()
        let tookBack = motion.takeBackFromRenderServer(at: 10.05)  // mutating: outside #expect, which reads a copy
        #expect(tookBack)
        let dt = 1.0 / 120
        for _ in 0..<3 { _ = motion.advance(dt, parameters: Self.spring) }
        var cpu = motion
        let handOff = 10.05 + 3 * dt, before = motion.state
        #expect(abs(before.zoomRate) > 0.1, "the main thread's zoom is not moving: \(before.zoomRate)")
        _ = motion.handToRenderServer(at: handOff, axes: Self.axes, parameters: Self.spring)
        let after = motion.shown(at: handOff)
        #expect(abs(after.zoom - before.zoom) < 1e-9, "the zoom jumped from \(before.zoom) to \(after.zoom)")
        #expect(abs(after.zoomRate - before.zoomRate) < 1e-6, "the zoom's speed went from \(before.zoomRate) to \(after.zoomRate)")
        #expect(abs(after.centerRate.x - before.centerRate.x) < 1e-6 && abs(after.centerRate.y - before.centerRate.y) < 1e-6)
        let h = 0.00001, later = motion.shown(at: handOff + h)
        #expect(abs((later.zoom - after.zoom) / h - before.zoomRate) < 0.01 * max(1, abs(before.zoomRate)), "the layer's zoom starts at rest")
        for frame in 1...30 {
            _ = cpu.advance(dt, parameters: Self.spring)
            let shown = motion.shown(at: handOff + Double(frame) * dt), stepped = cpu.shown
            #expect(abs(shown.zoom - stepped.zoom) < 1e-4, "frame \(frame): zoom \(shown.zoom), main thread \(stepped.zoom)")
            #expect(abs(shown.center.x - stepped.center.x) < 0.01 && abs(shown.center.y - stepped.center.y) < 0.01)
        }
        let landed = motion.shown(at: 30)
        #expect(abs(landed.zoom - Self.to.zoom) < 1e-9 && landed.zoomRate == 0)
    }

    /// A zoom passing through its target (ratio 1) still carries its speed: a carrier spring and a still one.
    @Test func aZoomAtItsTargetKeepsItsSpeed() {
        let zooms = CanvasCameraRenderSpring.zooms(ratio: 1, rate: 0.6, at: 0, parameters: Self.spring)
        #expect(zooms.count == 2, "\(zooms)")
        func product(_ time: Double) -> Double { zooms.reduce(1) { $0 * $1.scale(at: time).scale } }
        #expect(abs(product(0) - 1) < 1e-12, "the springs do not start at the zoom that shows")
        let h = 0.00001
        #expect(abs((product(h) - product(0)) / h - 0.6) < 0.01, "the springs start at \((product(h) - product(0)) / h), not 0.6")
        #expect(abs(product(20) - 1) < 1e-9)
        #expect(CanvasCameraRenderSpring.zooms(ratio: 1, rate: 0, at: 0, parameters: Self.spring).isEmpty)
    }

    @Test func theZoomTransformIsAScaleAboutItsPivot() throws {
        let zoom = CanvasZoomTransform(scale: 0.8, pivot: CGPoint(x: 600, y: 400), reach: 721)
        let matrix = try #require(zoom.layerValue as? NSValue).caTransform3DValue
        // The pivot stays where it is: 0.8 * 600 + m41 = 600.
        #expect(abs(0.8 * 600 + matrix.m41 - 600) < 1e-9 && abs(0.8 * 400 + matrix.m42 - 400) < 1e-9)
        #expect(CATransform3DIsIdentity(try #require(CanvasZoomTransform.springZero.layerValue as? NSValue).caTransform3DValue))
        let decoded = try #require(CanvasZoomTransform(layerValue: zoom.layerValue))
        #expect(abs(decoded.scale - 0.8) < 1e-9 && abs(decoded.pivot.x - 600) < 1e-6 && abs(decoded.pivot.y - 400) < 1e-6)
        #expect(zoom.springDelta(to: .springZero).scale == 0.8, "the offset from the identity is not the scale itself")
        #expect(abs(zoom.springExtent - 0.2 * 721) < 1e-9)
        #expect(CanvasZoomTransform(layerValue: NSValue(caTransform3D: CATransform3DMakeRotation(0.3, 0, 0, 1))) == nil)
    }
}

/// A canvas camera move on the render server in a real window (`motion.renderServer` on): the bounds rest
/// at the target in the change's turn, no display frames step the camera, Core Animation presents the move
/// from what showed as the closed form says, and the landing runs once.
///
/// The window is ordered in (a window on no screen does not animate), so the suite runs with the pane bench
/// (CMUX_PANE_BENCH=1, scripts/measure/split-spring.sh --suite=pane-bench): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct CanvasCameraRenderMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            return view
        }
    }

    /// Two panes shown as a canvas in a 1200 x 800 window.
    final class Canvas {
        let panes = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var motion: [Bool] = []
        private var observation: LayoutOverlaySyncObservation?

        init(renderServer: Bool) {
            let tree = SplitNode.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s", focusedPane: "a")
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer }, mainWork: linklessMainWork())
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            _ = model.toggleCanvas(seed: ["a": CGRect(x: 0, y: 0, width: 592, height: 800), "b": CGRect(x: 608, y: 0, width: 592, height: 800)],
                                   viewport: CGSize(width: 1200, height: 800))
            root.syncWithModel()
            observation = root.observeLayoutMotion { [weak self] moving in self?.motion.append(moving) }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
        var camera: CanvasCamera { model.canvases["s"]!.camera }

        func close() {
            observation = nil
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func aZoomRestsInItsTurnAndSpringsOnTheRenderServer() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let canvas = Canvas(renderServer: true)
        defer { canvas.close() }
        try #require(canvas.window.screen != nil, "the window is on no screen: nothing animates")
        let clock = try #require(canvas.root.layer)
        SplitRenderMotionTests.freeze(clock)
        let screen = canvas.screen
        let start = canvas.camera
        #expect(canvas.model.zoomCanvas(by: CanvasCamera.zoomStep))
        canvas.root.syncWithModel()
        let target = canvas.camera
        #expect(!screen.canvasState.camera.isMoving, "the main thread still steps the camera")
        #expect(!canvas.root.driver.isRunning, "the zoom asked the window's MotionClock for frames")
        let springs = try #require(screen.canvasState.camera.onRenderServer, "the render server took no camera springs")
        let rest = target.visibleRect(viewport: screen.frame.size)
        #expect(abs(screen.bounds.width - rest.width) < 0.5 && abs(screen.bounds.minX - rest.minX) < 0.5,
                "the bounds are not at the target in the zoom's turn: \(screen.bounds), not \(rest)")
        let layer = try #require(screen.layer)
        // Each presented time shows the zoom the closed form says (a pure zoom moves no center).
        for time in [0.0, 0.05, 0.12, 0.3] {
            SplitRenderMotionTests.seek(clock, to: time)
            let presented = try #require(layer.presentation())
            let zoom = Double(presented.sublayerTransform.m11) * target.zoom
            #expect(abs(zoom - springs.shown(at: time).zoom) < 0.002, "at \(time) s the layer shows zoom \(zoom), the record \(springs.shown(at: time).zoom)")
            #expect(abs(presented.bounds.minX - layer.bounds.minX) < 0.5, "a zoom about the center moved the center at \(time) s")
        }
        #expect(abs(springs.shown(at: 0).zoom - start.zoom) < 1e-9, "the zoom does not start from what showed")
    }

    /// The camera the screen layer presents at `time`: the center from the presented bounds origin, the zoom from
    /// the presented `sublayerTransform`, which must be a scale about the viewport center.
    static func presentedCamera(_ screen: ScreenContentView, rest: CanvasCamera, at time: Double, clock: CALayer) throws -> CanvasCamera {
        SplitRenderMotionTests.seek(clock, to: time)
        let layer = try #require(screen.layer), presented = try #require(layer.presentation())
        let axes = RenderLayerAxes(screen), m = presented.sublayerTransform
        let pivot = CGPoint(x: (0.5 - layer.anchorPoint.x) * layer.bounds.width, y: (0.5 - layer.anchorPoint.y) * layer.bounds.height)
        #expect(abs(m.m11 - m.m22) < 1e-6 && abs(m.m12) < 1e-9 && abs(m.m21) < 1e-9, "at \(time) s the layer shows no uniform scale: \(m)")
        #expect(abs(m.m41 - (1 - m.m11) * pivot.x) < 0.01 && abs(m.m42 - (1 - m.m11) * pivot.y) < 0.01,
                "at \(time) s the zoom does not pivot on the viewport center \(pivot): \(m)")
        return CanvasCamera(center: CGPoint(x: rest.center.x + (presented.bounds.minX - layer.bounds.minX) / axes.x,
                                            y: rest.center.y + (presented.bounds.minY - layer.bounds.minY) / axes.y),
                            zoom: rest.zoom * Double(m.m11))
    }

    static func gap(_ camera: CanvasCamera, _ state: CanvasCameraState) -> (center: CGFloat, zoom: Double) {
        (max(abs(camera.center.x - state.center.x), abs(camera.center.y - state.center.y)), abs(camera.zoom - state.zoom))
    }

    /// A move of the center and the zoom (a reveal with a zoom, as reset and overview make): the real layer
    /// presents the record's camera at each time, and the first move the main thread's path; a retarget at 0.08 s
    /// keeps what shows; a window resize keeps what shows and pivots on the new center; a pan takes the move back
    /// at what shows and leaves no spring on the layer.
    @Test func theLayerPresentsTheRecordsCamera() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let canvas = Canvas(renderServer: true)
        defer { canvas.close() }
        try #require(canvas.window.screen != nil, "the window is on no screen: nothing animates")
        let clock = try #require(canvas.root.layer)
        SplitRenderMotionTests.freeze(clock)
        let screen = canvas.screen
        let start = canvas.camera
        let first = CanvasCamera(center: CGPoint(x: start.center.x + 300, y: start.center.y - 120), zoom: start.zoom * 1.25)
        canvas.model.setCanvasCamera(first, for: "s")
        canvas.root.syncWithModel()
        #expect(!canvas.root.driver.isRunning, "the move asked the window's MotionClock for frames")
        var springs = try #require(screen.canvasState.camera.onRenderServer, "the render server took no camera springs")
        let parameters = Motion.panes.renderSpring(.scroll).parameters
        for time in [0.0, 0.03, 0.06] {
            let shown = try Self.presentedCamera(screen, rest: first, at: time, clock: clock)
            let gap = Self.gap(shown, springs.shown(at: time))
            #expect(gap.center < 0.5 && gap.zoom < 0.002, "at \(time) s the layer shows \(shown), the record \(springs.shown(at: time))")
            // The main thread's path from `start` (the signs and the axes, not the record's own arithmetic).
            let share = SpringValue.solve(displacement: 1, velocity: 0, time: time, parameters: parameters).displacement
            let expected = CanvasCameraState(center: CGPoint(x: first.center.x + (start.center.x - first.center.x) * share,
                                                             y: first.center.y + (start.center.y - first.center.y) * share),
                                             zoom: first.zoom + (start.zoom - first.zoom) * share, centerRate: .zero, zoomRate: 0)
            let off = Self.gap(shown, expected)
            #expect(off.center < 0.5 && off.zoom < 0.002, "at \(time) s the layer shows \(shown), the main thread's path \(expected)")
        }
        // A retarget at 0.08 s, from what shows.
        let before = try Self.presentedCamera(screen, rest: first, at: 0.08, clock: clock)
        let second = CanvasCamera(center: CGPoint(x: start.center.x - 200, y: start.center.y + 80), zoom: start.zoom * 0.8)
        canvas.model.setCanvasCamera(second, for: "s")
        canvas.root.syncWithModel()
        springs = try #require(screen.canvasState.camera.onRenderServer, "the retarget left the render server")
        let after = try Self.presentedCamera(screen, rest: second, at: 0.08, clock: clock)
        #expect(Self.gap(after, springs.shown(at: 0.08)).center < 0.5 && abs(after.zoom - before.zoom) < 0.002)
        #expect(abs(after.center.x - before.center.x) < 0.5 && abs(after.center.y - before.center.y) < 0.5,
                "the retarget moved what shows from \(before) to \(after)")
        for time in [0.12, 0.2] {
            let shown = try Self.presentedCamera(screen, rest: second, at: time, clock: clock)
            let gap = Self.gap(shown, springs.shown(at: time))
            #expect(gap.center < 0.5 && gap.zoom < 0.002, "at \(time) s the layer shows \(shown), the record \(springs.shown(at: time))")
        }
        // A window resize at 0.2 s: the move comes back and goes again about the new viewport center.
        let sized = try Self.presentedCamera(screen, rest: second, at: 0.2, clock: clock)
        canvas.window.setContentSize(NSSize(width: 1000, height: 800))
        canvas.root.needsLayout = true
        canvas.root.layoutSubtreeIfNeeded()
        try #require(screen.frame.width == 1000, "the screen did not resize: \(screen.frame)")
        springs = try #require(screen.canvasState.camera.onRenderServer, "the resize left the move on the main thread")
        let resized = try Self.presentedCamera(screen, rest: second, at: 0.2, clock: clock)
        let jump = Self.gap(resized, CanvasCameraState(center: sized.center, zoom: sized.zoom, centerRate: .zero, zoomRate: 0))
        #expect(jump.center < 0.5 && jump.zoom < 0.002, "the resize moved what shows from \(sized) to \(resized)")
        let later = try Self.presentedCamera(screen, rest: second, at: 0.25, clock: clock)
        let drift = Self.gap(later, springs.shown(at: 0.25))
        #expect(drift.center < 0.5 && drift.zoom < 0.002, "after the resize the layer shows \(later), the record \(springs.shown(at: 0.25))")
        // A pan takes the move back at what shows, and no camera spring stays on the layer.
        let panned = try Self.presentedCamera(screen, rest: second, at: 0.3, clock: clock)
        screen.canvasPan(by: .zero, ended: false)
        #expect(screen.canvasState.camera.onRenderServer == nil)
        let cpu = screen.canvasState.camera.shown
        #expect(abs(cpu.center.x - panned.center.x) < 0.5 && abs(cpu.center.y - panned.center.y) < 0.5 && abs(cpu.zoom - panned.zoom) < 0.002,
                "the main thread took \(cpu), the layer showed \(panned)")
        let layer = try #require(screen.layer)
        let left = (layer.animationKeys() ?? []).filter { $0.hasPrefix("cmux.renderSpring.") }
        #expect(left.isEmpty, "camera springs stayed on the layer: \(left)")
    }

    @Test func aRevealLandsOnceWithNoFrames() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let canvas = Canvas(renderServer: true)
        defer { canvas.close() }
        try #require(canvas.window.screen != nil, "the window is on no screen: nothing animates")
        let screen = canvas.screen
        var moved = canvas.camera
        moved.center.x += 300
        canvas.model.setCanvasCamera(moved, for: "s")
        canvas.root.syncWithModel()
        #expect(!canvas.root.driver.isRunning, "the reveal asked the window's MotionClock for frames")
        #expect(screen.canvasState.camera.onRenderServer != nil)
        #expect(canvas.motion == [true], "the layout motion does not start in the change's turn: \(canvas.motion)")
        let landed = await SplitRenderMotionTests.until { screen.canvasState.camera.onRenderServer == nil }
        #expect(landed, "the camera springs never landed")
        #expect(await SplitRenderMotionTests.until { canvas.motion.last == false }, "the layout motion never ended")
        #expect(canvas.motion == [true, false], "the landing ran \(canvas.motion)")
        #expect(screen.renderSpringsInFlight == 0)
    }

    @Test func withTheSwitchOffTheMainThreadStepsTheCamera() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let canvas = Canvas(renderServer: false)
        defer { canvas.close() }
        try #require(canvas.window.screen != nil, "the window is on no screen: nothing animates")
        #expect(canvas.model.zoomCanvas(by: CanvasCamera.zoomStep))
        canvas.root.syncWithModel()
        #expect(canvas.screen.canvasState.camera.isMoving)
        #expect(canvas.screen.canvasState.camera.onRenderServer == nil)
        #expect(canvas.root.driver.isRunning)
        // A frame steps it through the screen's own step (advanceFrame calls no camera step of its own).
        let before = canvas.screen.canvasState.camera.shown
        #expect(canvas.root.advanceFrame(1.0 / 120))
        #expect(canvas.screen.canvasState.camera.shown != before)
    }
}
