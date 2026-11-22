public import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextDesignTokens
import QuartzCore

/// A living wallpaper behind a window's content (``BackdropShader``): a `CAMetalLayer` drawn every
/// frame by ``BackdropShaderRenderer`` on its own queue, answering the pointer.
///
/// - The pointer: read each frame from the window (`mouseLocationOutsideOfEventStream`, so no
///   event is taken from the views above), eased toward, and its speed kept as an energy that
///   decays; the shader stirs, bends or pushes what is near it.
/// - A click anywhere in the window sends a ring out from where it lands (a local event monitor
///   that only looks, never consumes; four rings at most, the oldest replaced).
///
/// It moves on the same terms as a video wallpaper (``BackdropVideoView``): only while the window
/// is on screen, the screens awake, the session active, not in Low Power Mode, below a serious
/// thermal state and with looping motion allowed; otherwise it holds the frame it shows, and on
/// moving again eases its clock up from still over ``resumeRampSeconds`` (no motion onset). Frames
/// come from the window's ``FrameScheduler`` (no display link of its own), at most
/// ``maximumFramesPerSecond``, and one frame is encoded at a time: a slow GPU drops frames, never
/// queues them. The layer is drawn at one pixel per point: the shaders are soft fields, and a
/// Retina layer would cost four times the fill for nothing visible.
public final class BackdropShaderView: NSView {
    /// The shader drawn, nil when the wallpaper is no shader.
    public private(set) var shader: BackdropShader?
    /// Whether it draws the dark appearance's colors.
    public private(set) var dark = false
    /// The layer frames are presented in.
    public let metalLayer = CAMetalLayer()
    /// Tests: pins Reduce Motion, Low Power Mode or visibility for this view instead of the system's.
    public var reduceMotionOverride: Bool? { didSet { update() } }
    public var lowPowerOverride: Bool? { didSet { update() } }
    public var visibleOverride: Bool? { didSet { update() } }
    /// Tests: the pointer in view coordinates, in place of the window's.
    public var pointerOverride: CGPoint?

    /// The most frames a second it draws: smooth, at a quarter of a 120 Hz display's work.
    public static let maximumFramesPerSecond = 60.0
    /// Seconds a start or a resume takes to ease the clock from still to full speed. Attention is
    /// caught by motion that starts, not motion already under way (Abrams and Christ 2003), so the
    /// wallpaper never jumps from a held frame to full speed.
    public static let resumeRampSeconds = 2.5

    private let renderer: BackdropShaderRenderer?
    private var frameClient: FrameClient?
    /// What the window's video wallpaper view watches (screens asleep, session inactive): the
    /// backdrop wires it in (`WindowMaterialView`) and calls ``sightChanged()`` on each change.
    var sight: (() -> (screensAsleep: Bool, sessionInactive: Bool))?
    private let clicks = BackdropClickMonitor()
    /// The renderer's queue holds a frame; the next waits for it.
    private let inFlight = InFlightFrame()
    /// A held frame was asked for (a resize, an appearance flip) while one was being encoded: it is
    /// drawn when that one lands.
    private var stillPending = false
    /// The drawable's size in pixels: one per point. Main keeps it; the render queue sizes the
    /// layer's drawables to it, so only that queue touches the layer's drawable state.
    private(set) var pixelSize = CGSize(width: 1, height: 1)
    private var uniforms = BackdropShaderUniforms()
    private var lastFrame: CFTimeInterval?
    private var sinceDrawn: Double = .infinity
    private var lastPointer: CGPoint?
    private var nextRing = 0
    /// Whether the frame client was last told to move, and the seconds of clock since it began to.
    private var moving = false
    private var sinceResumed: Double = .infinity
    /// Frames presented (tests, `debug.themes`).
    public private(set) var framesDrawn = 0

    public init(frame frameRect: NSRect, renderer: BackdropShaderRenderer?) {
        self.renderer = renderer
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = BackdropShaderRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = 1
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.contentsGravity = .resize
        metalLayer.opacity = 0
        // Follows the view's size with no layout pass; layout() still sizes the drawable.
        metalLayer.frame = bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(metalLayer)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        syncDrawableSize()
        CATransaction.commit()
        // A resized window that is holding still redraws its frame at the new size.
        if !moves { drawStill() }
    }

    /// One drawable pixel per point of the view.
    private func syncDrawableSize() {
        let size = CGSize(width: max(bounds.width.rounded(), 1), height: max(bounds.height.rounded(), 1))
        pixelSize = size
    }

    /// Shows `shader` in the light or `dark` colors (nil: none). The same shader keeps its clock.
    public func show(_ shader: BackdropShader?, dark: Bool) {
        let changed = shader != self.shader
        self.dark = dark
        uniforms.dark = dark ? 1 : 0
        guard changed else { return update(redraw: true) }
        self.shader = shader
        uniforms.time = shader?.startTime ?? 0
        uniforms.rings = (.zero, .zero, .zero, .zero)
        uniforms.energy = 0
        lastPointer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.opacity = 0
        CATransaction.commit()
        syncDrawableSize()
        isHidden = shader == nil
        update(redraw: true)
    }

    /// Whether the shader moves now: shown, seen and allowed to.
    public var moves: Bool {
        let lowPower = lowPowerOverride ?? LowPowerMode.system.isEnabled
        let reduced = reduceMotionOverride ?? !Motion.panes.animatesLoops
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return onScreen && !lowPower && !hot && !reduced
    }

    /// Shown in a window that is on screen, with the screens awake and the session active.
    private var onScreen: Bool {
        guard shader != nil, !isHidden, renderer != nil, let window else { return false }
        let visible = visibleOverride ?? (window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden)
        let state = sight?() ?? (screensAsleep: false, sessionInactive: false)
        return visible && !state.screensAsleep && !state.sessionInactive
    }

    private func update(redraw: Bool = false) {
        if moves {
            if !moving { resumed() }
            moving = true
            if frameClient == nil {
                frameClient = FrameClient(owner: "backdrop-shader", view: self) { [weak self] tick in
                    self?.tick(tick) ?? false
                }
            }
            lastFrame = nil
            frameClient?.activate()
            clicks.start(in: self)
        } else {
            moving = false
            frameClient?.deactivate()
            clicks.stop()
            if redraw || framesDrawn == 0 { drawStill() }
        }
    }

    /// One display frame: advance the clock and the pointer, then draw when a frame is due and
    /// the last one was encoded.
    private func tick(_ tick: FrameTick) -> Bool {
        guard moves else { return false }
        let elapsed = lastFrame.map { min(max(tick.targetTimestamp - $0, 0), FrameScheduler.catchUpLimit) } ?? tick.frameElapsed
        lastFrame = tick.targetTimestamp
        advance(by: elapsed)
        sinceDrawn += elapsed
        guard sinceDrawn >= 1 / Self.maximumFramesPerSecond - 0.002 else { return true }
        sinceDrawn = 0
        draw()
        return true
    }

    /// Steps the clock, eases the shown pointer toward the real one, and lets the energy decay.
    func advance(by elapsed: Double) {
        uniforms.time += Float(elapsed * resumePace(over: elapsed))
        guard let pointer = pointerOverride ?? windowPointer() else { return }
        let target = SIMD2(Float(pointer.x * drawableScale.width), Float(pointer.y * drawableScale.height))
        let previous = lastPointer.map { SIMD2(Float($0.x * drawableScale.width), Float($0.y * drawableScale.height)) } ?? target
        lastPointer = pointer
        if uniforms.mouse == .zero { uniforms.mouse = target }
        let ease = Float(1 - exp(-elapsed * 9))
        uniforms.mouse += (target - uniforms.mouse) * ease
        let step = target - previous
        let speed = elapsed > 0 ? (step * step).sum().squareRoot() / Float(elapsed) : 0
        let short = Float(max(min(pixelSize.width, pixelSize.height), 1))
        // About a screen's short side a second fills the energy; it falls by half in ~0.35 s.
        uniforms.energy = min(1, uniforms.energy * Float(exp(-elapsed * 2)) + speed / short * Float(elapsed) * 3)
    }

    /// The motion starts again from the frame it held: the clock eases up from still.
    func resumed() { sinceResumed = 0 }

    /// The clock's mean speed (0 to 1) over the next `elapsed` seconds of a resume: a smoothstep
    /// over ``resumeRampSeconds``, averaged at both ends of the step.
    private func resumePace(over elapsed: Double) -> Double {
        guard sinceResumed < Self.resumeRampSeconds else { return 1 }
        func pace(_ t: Double) -> Double {
            let x = min(max(t / Self.resumeRampSeconds, 0), 1)
            return x * x * (3 - 2 * x)
        }
        let start = pace(sinceResumed)
        sinceResumed += elapsed
        return (start + pace(sinceResumed)) / 2
    }

    /// The window's pointer in this view's coordinates (outside the view too: the field falls off).
    private func windowPointer() -> CGPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Drawable pixels per point on each axis.
    private var drawableScale: CGSize {
        let drawable = pixelSize
        return CGSize(width: bounds.width > 0 && drawable.width > 0 ? drawable.width / bounds.width : 1,
                      height: bounds.height > 0 && drawable.height > 0 ? drawable.height / bounds.height : 1)
    }

    /// Sends a ring out from `point` (view coordinates) at the shader's current time.
    public func ring(at point: CGPoint) {
        let ring = SIMD4(Float(point.x * drawableScale.width), Float(point.y * drawableScale.height), uniforms.time, 1)
        uniforms.setRing(ring, at: nextRing)
        nextRing = (nextRing + 1) & 3
        uniforms.energy = min(1, uniforms.energy + 0.3)
    }

    /// The uniforms the next frame draws with (tests).
    var currentUniforms: BackdropShaderUniforms { uniforms }

    private func drawStill() {
        guard shader != nil, !isHidden, window != nil else { return }
        if lastPointer == nil, let pointer = pointerOverride ?? windowPointer() {
            lastPointer = pointer
            uniforms.mouse = SIMD2(Float(pointer.x * drawableScale.width), Float(pointer.y * drawableScale.height))
        }
        if !draw() { stillPending = true }
    }

    /// Hands one frame to the renderer's queue; false while the last is still being encoded.
    @discardableResult
    private func draw() -> Bool {
        guard let shader, let renderer else { return true }
        guard inFlight.begin() else { return false }
        var next = uniforms
        next.resolution = SIMD2(Float(pixelSize.width), Float(pixelSize.height))
        let frame = next, target = BackdropShaderTarget(layer: metalLayer), inFlight = self.inFlight
        renderer.queue.async {
            let drawn = renderer.draw(shader, uniforms: frame, into: target)
            inFlight.end()
            MainDelivery().run { [weak self] in self?.frameEnded(drawn: drawn) }
        }
        return true
    }

    /// A frame left the render queue: count it, fade the first one in over the poster (the motion
    /// policy's fade), and draw a held frame that was asked for meanwhile.
    private func frameEnded(drawn: Bool) {
        if stillPending, !moves {
            stillPending = false
            drawStill()
        }
        guard drawn else { return }
        framesDrawn += 1
        guard metalLayer.opacity == 0, window != nil, shader != nil else { return }
        Motion.panes.set(metalLayer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameClient?.deactivate()
        frameClient = nil
        guard window != nil else { return clicks.stop() }
        update(redraw: true)
    }

    override public var isHidden: Bool {
        didSet { if isHidden != oldValue { update() } }
    }

    /// The window's visibility, the power or heat, or the motion settings changed (told by the
    /// video wallpaper view's observers, `WindowMaterialView`): move or hold.
    public func sightChanged(closing: Bool = false) {
        guard !closing else {
            frameClient?.deactivate()
            return clicks.stop()
        }
        update()
    }
}

/// Sends a ring out from each click in a living wallpaper's window: a local event monitor that only
/// looks and never consumes the event.
@MainActor
final class BackdropClickMonitor {
    private var monitor: Any?

    /// Watches clicks in `view`'s window while it moves.
    func start(in view: BackdropShaderView) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak view] event in
            let target = event.window.map(ObjectIdentifier.init), location = event.locationInWindow
            // main-proof: AppKit calls local event monitors on the main thread, in its event dispatch.
            MainActor.assumeIsolated {
                guard let view, let window = view.window, target == ObjectIdentifier(window) else { return }
                view.ring(at: view.convert(location, from: nil))
            }
            return event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

/// The layer a frame is drawn into, carried to the renderer's queue. Only the renderer's serial
/// queue draws into or sizes this layer, one frame at a time (InFlightFrame); main sets only its
/// frame, opacity and place, under CATransaction.
// crash-allow: the layer's drawable state is touched only on the renderer's serial queue (see above)
nonisolated struct BackdropShaderTarget: @unchecked Sendable {
    let layer: CAMetalLayer
}

/// Whether a frame is on the renderer's queue: claimed on main, cleared on the queue.
private nonisolated final class InFlightFrame: Sendable {
    private let busy = Mutex(false)

    /// Claims the slot; false while a frame is still being encoded.
    func begin() -> Bool {
        busy.withLock { busy in
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    func end() {
        busy.withLock { $0 = false }
    }
}
