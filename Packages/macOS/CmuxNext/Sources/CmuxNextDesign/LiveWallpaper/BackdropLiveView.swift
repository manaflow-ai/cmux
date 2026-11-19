public import AppKit
import CCmuxWallpaperFFI
public import CmuxNextDesignTokens
import CmuxNextWakeups
import Metal
import QuartzCore

/// A live wallpaper behind a window's content (plans/cmux-next/live-wallpapers.md): its program runs
/// on the GPU for every pixel of a `CAMetalLayer`, paced by the view's own display link.
///
/// Whether it draws is the Rust scheduler's answer (`cmux_wallpaper_schedule`), asked after every
/// event that can change it and on each frame: occlusion, coverage (``BackdropCoverage``),
/// miniaturize, app hide, screens asleep, session switch, Low Power Mode, thermal state, Reduce
/// Motion and the animation switches, the Settings cap (`appearance.liveWallpaperFrameRate`), the
/// GPU strikes, a pointer move, a key press, a resize and a theme change. On hold the display
/// link is invalidated, so a held wallpaper does no work and runs no timer; it shows the last frame
/// it drew, like a picture. An idle hold (20 s with no pointer motion, key or theme change) ends on
/// the next pointer move over the window, key press in it or theme change, all events, never a poll.
/// Coverage is sampled every 3 s while it runs or rests on coverage, as the video wallpaper does.
///
/// The main thread only asks the scheduler, steps the pointer and packs the Frame uniform;
/// the drawable, the encode and the commit run on the render queue (``LiveWallpaperRenderer``),
/// and the Metal program is built once per wallpaper off the main thread (``LiveWallpaperPrograms``).
public final class BackdropLiveView: NSView {
    /// The wallpaper shown, nil for none.
    public private(set) var wallpaper: LiveWallpaper?
    /// Tests: pin Reduce Motion, Low Power Mode or visibility for this view instead of the system's.
    public var reduceMotionOverride: Bool? { didSet { update() } }
    public var lowPowerOverride: Bool? { didSet { update() } }
    public var visibleOverride: Bool? { didSet { update() } }
    /// Tests: the windows above this one, in place of the screen's.
    public var windowsAboveOverride: (() -> [BackdropCoverage.Window])?

    private let metalLayer: CAMetalLayer
    private let programs: LiveWallpaperPrograms
    private let renderer: LiveWallpaperRenderer?
    private var pipeline: LiveWallpaperPipeline?
    private var pipelineLoad: Task<Void, Never>?
    private var link: CADisplayLink?
    private var linkFPS: UInt32 = 0
    /// The scheduler's last answer.
    private var decision = CmuxWallpaperDecision()
    /// The render scale now: the manifest's, halved by the scheduler after GPU strikes.
    private var scale: Float = 1
    private var strikes: UInt32 = 0
    private var hasFrame = false
    /// Seconds since shown, counted only over drawn frames (a hold does not move it).
    private var time: Float = 0
    private var frameNumber: Float = 0
    /// When the last frame was drawn while running; nil after a hold, so the first frame after one
    /// continues from where it stopped.
    private var lastFrameAt: CFTimeInterval?
    private var lastActivity: CFTimeInterval = 0
    private var lastPointerMove: CFTimeInterval = -.infinity
    private var pointer = CmuxWallpaperPointer()
    /// The pointer's recent path (`Frame.trail`), in backing pixels like ``pointer``.
    private var trail = CmuxWallpaperTrail()
    private var colors: LiveWallpaperColors?
    private let seed = Float.random(in: 0..<1)
    private var keyMonitor: Any?
    private var tracking: NSTrackingArea?
    /// The window's and the app's events, watched while in a window (Low Power Mode included).
    private lazy var signals = BackdropPlaybackSignals { [weak self] signal in self?.signalled(signal) }
    private var coverage = BackdropCoverage()
    private let coverageTimer = DemandTimer(owner: "backdrop-live-coverage")
    /// GPU seconds and frames drawn since shown (`debug.themes`, the wallpaper-cost bench).
    private(set) var gpuSeconds: Double = 0
    private(set) var framesDrawn = 0

    /// A view that builds its programs in `programs` (the app's, ``BackdropImageStore/livePrograms``).
    public init(frame frameRect: NSRect, programs: LiveWallpaperPrograms) {
        let layer = CAMetalLayer()
        metalLayer = layer
        self.programs = programs
        renderer = LiveWallpaperGPU.shared.map { gpu in
            layer.device = gpu.device
            return LiveWallpaperRenderer(layer: layer, gpu: gpu, queue: programs.renderQueue)
        }
        super.init(frame: frameRect)
        metalLayer.pixelFormat = LiveWallpaperGPU.pixelFormat
        metalLayer.framebufferOnly = true
        // Premultiplied: a program may leave the window's material showing through.
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        metalLayer.contentsGravity = .resize
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        isHidden = true
        setAccessibilityElement(false)
        cmux_wallpaper_pointer_reset(&pointer)
        cmux_wallpaper_trail_reset(&trail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func makeBackingLayer() -> CALayer { metalLayer }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: What it shows

    /// Shows `wallpaper` (nil: none). The same wallpaper keeps its program, time and frame.
    public func show(_ wallpaper: LiveWallpaper?) {
        guard wallpaper != self.wallpaper else { return update() }
        stopLink()
        pipelineLoad?.cancel()
        pipelineLoad = nil
        pipeline = nil
        self.wallpaper = wallpaper
        isHidden = wallpaper == nil
        (hasFrame, time, frameNumber, strikes, gpuSeconds, framesDrawn) = (false, 0, 0, 0, 0, 0)
        scale = wallpaper?.scale ?? 1
        lastActivity = CACurrentMediaTime()
        cmux_wallpaper_pointer_reset(&pointer)
        cmux_wallpaper_trail_reset(&trail)
        updateTracking()
        updateKeyMonitor()
        guard let wallpaper else { return stopCoverage() }
        // task-owner: one program load per shown wallpaper; a new show cancels it
        pipelineLoad = Task { [weak self, programs] in
            let built = await programs.pipeline(for: wallpaper)
            guard !Task.isCancelled, let self, self.wallpaper == wallpaper else { return }
            self.pipeline = built
            self.update()
        }
    }

    /// The theme changed (``WindowMaterialView/apply(_:tint:)`` calls it on every theme apply): a
    /// change of its colors is activity, and a held wallpaper that is seen draws once in them.
    public func themeDidChange() {
        guard wallpaper != nil, window != nil else { return }
        let fresh = LiveWallpaperColors(themeTokens)
        guard fresh != colors else { return }
        colors = fresh
        hasFrame = false
        noteActivity()
    }

    // MARK: The scheduler

    /// Asks the scheduler with what the view knows now and follows its answer: run the link at its
    /// rate, or hold with the link gone (drawing one frame first when it says so).
    @discardableResult
    private func update() -> CmuxWallpaperDecision? {
        guard let wallpaper, pipeline != nil, renderer != nil, let window, !isHidden else {
            stopLink()
            stopCoverage()
            return nil
        }
        var input = scheduleInput(wallpaper, window: window, now: CACurrentMediaTime())
        let answer = cmux_wallpaper_schedule(&input)
        if answer.scale != scale {
            scale = answer.scale
            strikes = 0
        }
        decision = answer
        if answer.run {
            startLink(fps: answer.fps)
            startCoverage()
        } else {
            stopLink()
            // Resting on coverage: the samples are how it learns it shows again. Every other hold runs nothing.
            if answer.hold_reason == HoldReason.covered { startCoverage() } else { stopCoverage() }
            if answer.draw_one { drawFrame(at: CACurrentMediaTime()) }
        }
        return answer
    }

    private func scheduleInput(_ wallpaper: LiveWallpaper, window: NSWindow, now: CFTimeInterval) -> CmuxWallpaperScheduleInput {
        var input = CmuxWallpaperScheduleInput()
        input.seconds_since_activity = now - lastActivity
        input.seconds_since_pointer = lastPointerMove.isFinite ? now - lastPointerMove : 1e9
        input.settings_fps_cap = UInt32(clamping: DesignSettings.shared.liveWallpaperFrameRate)
        input.manifest_fps = wallpaper.fps
        input.gpu_strikes = strikes
        input.scale = scale
        input.visible = visibleOverride ?? window.occlusionState.contains(.visible)
        input.coverage_resting = coverage.resting
        input.minimized = window.isMiniaturized
        input.app_hidden = NSApp.isHidden
        input.screens_asleep = signals.screensAsleep
        input.session_inactive = signals.sessionInactive
        input.low_power = lowPowerOverride ?? LowPowerMode.system.isEnabled
        input.thermal_serious = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        input.reduce_motion = reduceMotionOverride ?? Motion.reduceMotion
        // The master switch, `ui.animations.panes` or speed "off".
        input.animations_off = !Motion.panes.isEnabled
        input.interactive = wallpaper.interactive
        input.idle_after_s = wallpaper.idleAfter
        input.has_frame = hasFrame
        return input
    }

    /// Something the person did that keeps the wallpaper awake (a key, a resize, a theme change);
    /// a held one asks the scheduler again at once.
    private func noteActivity() {
        lastActivity = CACurrentMediaTime()
        if link == nil { update() }
    }

    // MARK: Frames

    private func startLink(fps: UInt32) {
        if link == nil {
            // wakeup-allow: the wallpaper's own link at its own rate (15-60 fps), only while the scheduler says run;
            // invalidated on every hold, so a held wallpaper runs nothing. The window's FrameScheduler runs at 80-120 Hz.
            let made = displayLink(target: LiveLinkTarget(self), selector: #selector(LiveLinkTarget.tick(_:)))
            made.add(to: .main, forMode: .common)
            link = made
            linkFPS = 0
        }
        guard linkFPS != fps, let link else { return }
        let rate = Float(fps)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        linkFPS = fps
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        linkFPS = 0
        lastFrameAt = nil
    }

    // perf-hot: 1ms live-wallpaper-frame (every live wallpaper frame: ask the scheduler, pack, hand off to the render queue)
    fileprivate func tick(_ link: CADisplayLink) {
        guard let answer = update(), answer.run else { return }
        drawFrame(at: CACurrentMediaTime())
    }

    /// Draws one frame now: the pointer stepped to `now`, the uniform packed, the encode queued.
    // perf-hot: 1ms live-wallpaper-frame (the per-frame draw on the main thread: no wait, no allocation but the uniform)
    private func drawFrame(at now: CFTimeInterval) {
        guard let wallpaper, let pipeline, let renderer, let window else { return }
        let backing = Float(window.backingScaleFactor)
        let pixelsPerPoint = backing * scale
        let width = max(1, (Float(bounds.width) * pixelsPerPoint).rounded())
        let height = max(1, (Float(bounds.height) * pixelsPerPoint).rounded())
        // A frame after a hold continues from where the last one stopped.
        let delta = lastFrameAt.map { Float(min(max(now - $0, 0), 0.25)) } ?? 0
        cmux_wallpaper_pointer_advance(&pointer, now)
        let palette = colors ?? LiveWallpaperColors(themeTokens)
        colors = palette
        var frame = LiveWallpaperFrame(colors: palette)
        frame.time = time + delta
        frame.delta = delta
        frame.number = frameNumber
        frame.width = width
        frame.height = height
        frame.pixelsPerPoint = pixelsPerPoint
        frame.seed = seed
        // The pointer is kept in backing pixels; the program sees rendered pixels.
        frame.pointer = SIMD2(pointer.x, pointer.y) * scale
        frame.velocity = SIMD2(pointer.vx, pointer.vy) * scale
        frame.presence = pointer.presence
        frame.sinceMoved = cmux_wallpaper_pointer_since_moved(&pointer, now)
        frame.buttonDown = pointer.inside && NSEvent.pressedMouseButtons != 0
        frame.params = wallpaper.params
        let drawn = renderer.draw(frame.packed(trail: trail, at: now, scale: scale), pipeline: pipeline, drawableSize: CGSize(width: CGFloat(width), height: CGFloat(height))) {
            [weak self] milliseconds in
            MainDelivery().run { self?.frameCompleted(milliseconds) }
        }
        // The last frame is still on the GPU: this tick draws nothing, and time does not move.
        guard drawn else { return }
        time += delta
        frameNumber += 1
        hasFrame = true
        lastFrameAt = link == nil ? nil : now
        framesDrawn += 1
    }

    /// A frame's GPU time: three over 4 ms in a row halve the scale at the next ask.
    private func frameCompleted(_ milliseconds: Double?) {
        guard let milliseconds else { return }
        gpuSeconds += milliseconds / 1000
        strikes = cmux_wallpaper_gpu_strikes(strikes, Float(milliseconds))
    }

    // MARK: Pointer, keys, size

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard wallpaper != nil, window != nil else { return }
        // Every window that shows a wallpaper, key or not: a background window's wallpaper follows the pointer too.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override public func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override public func mouseEntered(with event: NSEvent) { pointerMoved(event) }

    override public func mouseExited(with event: NSEvent) {
        cmux_wallpaper_pointer_leave(&pointer)
    }

    /// The pointer over the window, in backing pixels from the top left; it wakes an idle
    /// interactive wallpaper.
    private func pointerMoved(_ event: NSEvent) {
        guard let wallpaper, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let backing = Float(window.backingScaleFactor)
        let now = CACurrentMediaTime()
        let (x, y) = (Float(point.x) * backing, Float(bounds.height - point.y) * backing)
        cmux_wallpaper_pointer_update(&pointer, x, y, now)
        cmux_wallpaper_trail_update(&trail, x, y, now)
        lastPointerMove = now
        if link == nil, wallpaper.interactive { update() }
    }

    /// A key press in this window or a window it owns (a page, a panel) is activity.
    private func updateKeyMonitor() {
        let wanted = wallpaper != nil && window != nil
        if wanted, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      WindowMaterialView.family(of: window, holds: event.window, owner: { $0.parent ?? $0.sheetParent })
                else { return event }
                self.noteActivity()
                return event
            }
        } else if !wanted, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // A live resize redraws every frame while it runs (or stretches the held frame) and settles at its end.
        if changed, !inLiveResize { sizeDidChange() }
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        sizeDidChange()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizeDidChange()
    }

    /// A new size is activity, and a held wallpaper that is seen draws once at it.
    private func sizeDidChange() {
        guard wallpaper != nil, window != nil else { return }
        hasFrame = false
        noteActivity()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    // MARK: Window and system events

    override public var isHidden: Bool {
        didSet { if isHidden != oldValue { update() } }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        signals.watch(window)
        stopLink()
        updateTracking()
        updateKeyMonitor()
        guard window != nil else { return stopCoverage() }
        colors = nil
        hasFrame = false
        themeDidChange()
        update()
    }

    private func signalled(_ signal: BackdropPlaybackSignals.Signal) {
        switch signal {
        // A closed window keeps its views: stop now, not when the view goes.
        case .closing:
            stopLink()
            stopCoverage()
            return
        // A window brought to the front shows: run now; the next samples rest it again if needed.
        case .raised: coverage.reset()
        case .changed: break
        }
        update()
    }

    // MARK: Coverage (as BackdropVideoView)

    /// Samples how much of the window other windows hide, and asks the scheduler again when the rest flips.
    public func sampleCoverage() {
        guard let window else { return }
        let above = windowsAboveOverride?() ?? BackdropCoverage.windows(above: window.windowNumber)
        let resting = coverage.resting
        coverage.sample(BackdropCoverage.covered(BackdropVideoView.screenFrame(window.frame), by: above,
                                                 ignoring: BackdropVideoView.descendants(of: window)))
        if coverage.resting != resting { update() }
    }

    private func startCoverage() {
        guard !coverageTimer.isScheduled else { return }
        coverageTimer.schedule(after: .seconds(BackdropCoverage.interval)) { @MainActor [weak self] in
            self?.coverageFired()
        }
    }

    private func coverageFired() {
        sampleCoverage()
        if link != nil || decision.hold_reason == HoldReason.covered { startCoverage() }
    }

    private func stopCoverage() {
        coverageTimer.cancel()
        coverage.reset()
    }

    // MARK: State (debug.themes, the wallpaper-cost bench)

    /// What the view does now: `live` (the wallpaper id), `live_state` (`run` or `hold:<reason>`),
    /// `live_fps`, `live_scale`, `live_frames`, `live_gpu_s` (GPU seconds since shown),
    /// `live_strikes` and `live_pointer_settled`; empty with no wallpaper.
    var debugState: [String: String] {
        guard let wallpaper else { return [:] }
        let state = link != nil ? "run" : "hold:\(HoldReason.name(decision.hold_reason))"
        return ["live": wallpaper.id, "live_state": pipeline == nil ? "loading" : state, "live_fps": String(linkFPS),
                "live_scale": String(scale), "live_frames": String(framesDrawn), "live_gpu_s": String(format: "%.4f", gpuSeconds),
                "live_strikes": String(strikes), "live_pointer_settled": cmux_wallpaper_pointer_settled(&pointer) ? "true" : "false"]
    }
}

/// The scheduler's hold reasons (`CmuxWallpaperDecision.hold_reason`).
private nonisolated enum HoldReason {
    static let covered: UInt8 = 2
    private static let names = ["", "occluded", "covered", "minimized", "app-hidden", "screens-asleep", "session-inactive",
                                "low-power", "thermal", "reduce-motion", "animations-off", "too-heavy", "idle"]

    static func name(_ reason: UInt8) -> String {
        Int(reason) < names.count ? names[Int(reason)] : String(reason)
    }
}

/// The display link's target: weak, so the link never keeps the view.
private final class LiveLinkTarget: NSObject {
    private weak var view: BackdropLiveView?

    init(_ view: BackdropLiveView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
