import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// The canvas camera's render-server springs as values (chrome-parity p03-rendering-031): a hand-off from
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
        #expect(motion.takeBackFromRenderServer(at: 10.05))
        #expect(motion.onRenderServer == nil)
        #expect(motion.state == shown, "the main thread starts from \(motion.state), not \(shown)")
        #expect(motion.isMoving && motion.target == Self.to)
        #expect(!motion.takeBackFromRenderServer(at: 10.06), "a second take-back found springs")
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
            root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer })
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
