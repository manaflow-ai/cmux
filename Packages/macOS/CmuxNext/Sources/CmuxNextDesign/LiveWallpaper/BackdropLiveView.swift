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
///
/// A motion scene (plans/cmux-next/motion-scenes.md) draws with the one scene engine program and a
/// scene player of its own (``LiveWallpaperScenePlayer``): each frame the player steps the keyframes and
/// physics and packs the Scene block, bound at fragment buffer 1 with the badge at texture 0. A scene
/// with nothing moving is at rest and the scheduler holds it (`at_rest`, hold reason 13) with the link
/// gone. Every press and release over the backdrop is stepped into the player at once, with no draw
/// (a move only while it rests), and a held view asks again: a press on the badge wakes its physics, and
/// it runs. The physics runs on the pointer's monotonic clock (`CACurrentMediaTime`). Presses are watched
/// by a local monitor that never consumes them, and only while a scene shows.
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
    /// The last frame's GPU milliseconds (the wallpaper-cost bench's per-frame number).
    private var lastGPUMilliseconds: Double = 0

    /// Who a scene's badge shows: the app sets the signed-in account's; this Mac's user by default.
    public var badgeIdentity: LiveWallpaperBadgeIdentity = .macUser {
        didSet { if badgeIdentity != oldValue { refreshBadge() } }
    }
    /// A motion scene's player (its keyframes and physics world); nil for a program wallpaper.
    private var scene: LiveWallpaperScenePlayer?
    /// The Scene block, reused frame to frame (``LiveWallpaperScenePlayer/floats`` floats).
    private var sceneBlock: [Float] = []
    /// The badge for the scene's image slot, drawn once per identity and colors; nil until drawn.
    private var badgeImage: LiveWallpaperSceneImage?
    private var badgeKey: String?
    private var badgeLoad: Task<Void, Never>?
    /// A press that began over the backdrop (not on a pane or a control), held down: the scene's button.
    private var sceneButtonDown = false
    private var pressMonitor: Any?
    /// Seconds spent in the scene's evaluate since shown, and the last call's microseconds (the
    /// wallpaper-cost bench's Rust evaluate number).
    private(set) var evaluateSeconds: Double = 0
    private var lastEvaluateMicros: Double = 0

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
        guard wallpaper != self.wallpaper else { update(); return }
        stopLink()
        pipelineLoad?.cancel()
        pipelineLoad = nil
        pipeline = nil
        self.wallpaper = wallpaper
        isHidden = wallpaper == nil
        (hasFrame, time, frameNumber, strikes, gpuSeconds, framesDrawn) = (false, 0, 0, 0, 0, 0)
        (evaluateSeconds, lastEvaluateMicros, lastGPUMilliseconds) = (0, 0, 0)
        scale = wallpaper?.scale ?? 1
        lastActivity = CACurrentMediaTime()
        cmux_wallpaper_pointer_reset(&pointer)
        cmux_wallpaper_trail_reset(&trail)
        // A scene gets a player of its own (a fresh physics world); the badge is drawn again for it.
        scene = wallpaper?.makeScenePlayer()
        sceneBlock = []
        sceneButtonDown = false
        badgeLoad?.cancel()
        (badgeLoad, badgeImage, badgeKey) = (nil, nil, nil)
        updateTracking()
        updateKeyMonitor()
        updatePressMonitor()
        refreshBadge()
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
        refreshBadge()
        noteActivity()
    }

    /// Draws the scene's badge (the person's picture or initials, and name) in the theme's colors
    /// off the main thread and uploads it once; a held scene that is seen draws once with it. Nothing
    /// for a scene without an image slot or a program wallpaper.
    private func refreshBadge() {
        guard let scene, scene.hasImage, window != nil else { return }
        let palette = colors ?? LiveWallpaperColors(themeTokens)
        let key = "\(badgeIdentity.key)|\(palette.key)"
        guard key != badgeKey else { return }
        badgeKey = key
        badgeLoad?.cancel()
        let badge = LiveWallpaperBadge(identity: badgeIdentity, colors: palette)
        let shown = wallpaper
        // task-owner: one badge draw per shown scene, identity and colors; a newer one cancels it
        badgeLoad = Task { [weak self] in
            let image = await badge.sceneImage()
            guard !Task.isCancelled, let self, self.wallpaper == shown, self.badgeKey == key else { return }
            self.badgeImage = image
            self.hasFrame = false
            self.update()
        }
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
        // A scene with nothing moving holds at rest; a press wakes it (``feedScene(press:)``).
        input.at_rest = scene?.atRest ?? false
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

    /// Draws one frame now: the pointer stepped to `now`, the uniform packed (and a scene's block),
    /// the encode queued.
    // perf-hot: 1ms live-wallpaper-frame (the per-frame draw on the main thread: no wait, no allocation but the uniform and a scene's block)
    private func drawFrame(at now: CFTimeInterval) {
        guard let pipeline, let renderer, let frame = makeFrame(at: now) else { return }
        var sceneInputs: LiveWallpaperSceneInputs?
        if scene != nil {
            guard evaluateScene(frame, now: now) else { return }
            sceneInputs = LiveWallpaperSceneInputs(block: sceneBlock, image: badgeImage)
        }
        let size = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        let drawn = renderer.draw(frame.packed(trail: trail, at: now, scale: scale), scene: sceneInputs, pipeline: pipeline, drawableSize: size) { [weak self] milliseconds in
            MainDelivery().run { self?.frameCompleted(milliseconds) }
        }
        // The last frame is still on the GPU: this tick draws nothing, and time does not move.
        guard drawn else { return }
        time += frame.delta
        frameNumber += 1
        hasFrame = true
        lastFrameAt = link == nil ? nil : now
        framesDrawn += 1
    }

    /// The frame for `now`: the pointer stepped to it, time continued from the last drawn frame (a
    /// frame after a hold continues from where the last one stopped). Nil without a wallpaper or window.
    private func makeFrame(at now: CFTimeInterval) -> LiveWallpaperFrame? {
        guard let wallpaper, let window else { return nil }
        let backing = Float(window.backingScaleFactor)
        let pixelsPerPoint = backing * scale
        let delta = lastFrameAt.map { Float(min(max(now - $0, 0), 0.25)) } ?? 0
        cmux_wallpaper_pointer_advance(&pointer, now)
        let palette = colors ?? LiveWallpaperColors(themeTokens)
        colors = palette
        var frame = LiveWallpaperFrame(colors: palette)
        frame.time = time + delta
        frame.delta = delta
        frame.number = frameNumber
        frame.width = max(1, (Float(bounds.width) * pixelsPerPoint).rounded())
        frame.height = max(1, (Float(bounds.height) * pixelsPerPoint).rounded())
        frame.pixelsPerPoint = pixelsPerPoint
        frame.seed = seed
        // The pointer is kept in backing pixels; the program sees rendered pixels.
        frame.pointer = SIMD2(pointer.x, pointer.y) * scale
        frame.velocity = SIMD2(pointer.vx, pointer.vy) * scale
        frame.presence = pointer.presence
        frame.sinceMoved = cmux_wallpaper_pointer_since_moved(&pointer, now)
        // A scene's button is a press that began over the backdrop, never one on a pane.
        frame.buttonDown = scene != nil ? sceneButtonDown : pointer.inside && NSEvent.pressedMouseButtons != 0
        frame.params = wallpaper.params
        return frame
    }

    /// Steps the scene's physics to `now` (the pointer's monotonic clock) with `frame`'s pointer and
    /// button, and packs its block into ``sceneBlock``, timing the call.
    // perf-hot: 50us scene-evaluate (every drawn motion scene frame, each press and release, and each move while it rests)
    private func evaluateScene(_ frame: LiveWallpaperFrame, now: CFTimeInterval) -> Bool {
        guard let scene else { return false }
        let start = CACurrentMediaTime()
        let evaluated = scene.evaluate(frame, now: now, into: &sceneBlock)
        let spent = CACurrentMediaTime() - start
        evaluateSeconds += spent
        lastEvaluateMicros = spent * 1_000_000
        return evaluated
    }

    /// Pointer input for a scene, with no draw: a press or a release is stepped in at once (the
    /// physics sees the button's edges only through evaluate, so a click between two frames is not
    /// missed, and a press on a draggable body wakes it); a move only while the scene is held at
    /// rest (a running scene gets it with the next frame). The caller then asks the scheduler again.
    /// One evaluate per event, and nothing while no input comes.
    private func feedScene(press: Bool) {
        guard scene != nil, press || (link == nil && decision.hold_reason == HoldReason.atRest) else { return }
        let now = CACurrentMediaTime()
        guard let frame = makeFrame(at: now) else { return }
        _ = evaluateScene(frame, now: now)
    }

    /// A frame's GPU time: three over 4 ms in a row halve the scale at the next ask.
    private func frameCompleted(_ milliseconds: Double?) {
        guard let milliseconds else { return }
        lastGPUMilliseconds = milliseconds
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
    /// interactive wallpaper. `press`: a scene's press or release (``scenePress(_:)``), stepped into the
    /// scene at once, after which a held wallpaper asks the scheduler again (a press on the badge wakes it).
    private func pointerMoved(_ event: NSEvent, press: Bool = false) {
        guard let wallpaper, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let backing = Float(window.backingScaleFactor)
        let now = CACurrentMediaTime()
        let (x, y) = (Float(point.x) * backing, Float(bounds.height - point.y) * backing)
        cmux_wallpaper_pointer_update(&pointer, x, y, now)
        cmux_wallpaper_trail_update(&trail, x, y, now)
        lastPointerMove = now
        feedScene(press: press)
        if link == nil, wallpaper.interactive || press { update() }
    }

    /// Watches presses for a scene (a drag of its badge): a local monitor that hands every event on
    /// unchanged, installed only while a scene shows in a window.
    private func updatePressMonitor() {
        let wanted = scene != nil && window != nil
        if wanted, pressMonitor == nil {
            pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.scenePress(event)
                return event
            }
        } else if !wanted, let monitor = pressMonitor {
            NSEvent.removeMonitor(monitor)
            pressMonitor = nil
            sceneButtonDown = false
        }
    }

    /// A press, drag or release in this window: the scene's button goes down only for a press over the
    /// backdrop itself, and its drag moves the pointer (a tracking area sends no moves while a button is down).
    private func scenePress(_ event: NSEvent) {
        guard scene != nil, let window, event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            guard pressReachesBackdrop(event, in: window) else { return }
            sceneButtonDown = true
        case .leftMouseUp:
            guard sceneButtonDown else { return }
            sceneButtonDown = false
        default:
            guard sceneButtonDown else { return }
        }
        pointerMoved(event, press: event.type != .leftMouseDragged)
    }

    /// Whether a press lands where the backdrop shows: the deepest view under it is no control and
    /// takes no first responder (a terminal, a page, a field or a button does). The press still goes to
    /// that view; this only decides whether the scene sees it too.
    private func pressReachesBackdrop(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return true }
        return !(hit is NSControl) && !hit.acceptsFirstResponder
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
        sceneButtonDown = false
        updateTracking()
        updateKeyMonitor()
        updatePressMonitor()
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
    /// `live_strikes` and `live_pointer_settled`; empty with no wallpaper. The cost bench's per-frame
    /// numbers: `live_gpu_ms` (the last frame's GPU milliseconds), and for a motion scene `live_scene`
    /// ("true"), `live_at_rest`, `live_eval_us` (the last Rust evaluate, microseconds) and `live_eval_s`
    /// (evaluate seconds since shown; over `live_frames` it is the mean).
    var debugState: [String: String] {
        guard let wallpaper else { return [:] }
        let state = link != nil ? "run" : "hold:\(HoldReason.name(decision.hold_reason))"
        var values = ["live": wallpaper.id, "live_state": pipeline == nil ? "loading" : state, "live_fps": String(linkFPS),
                      "live_scale": String(scale), "live_frames": String(framesDrawn), "live_gpu_s": String(format: "%.4f", gpuSeconds),
                      "live_gpu_ms": String(format: "%.3f", lastGPUMilliseconds), "live_strikes": String(strikes),
                      "live_pointer_settled": cmux_wallpaper_pointer_settled(&pointer) ? "true" : "false"]
        if let scene {
            values["live_scene"] = "true"
            values["live_at_rest"] = scene.atRest ? "true" : "false"
            values["live_eval_us"] = String(format: "%.1f", lastEvaluateMicros)
            values["live_eval_s"] = String(format: "%.6f", evaluateSeconds)
            values["live_badge"] = scene.hasImage ? (badgeImage == nil ? "loading" : "shown") : "none"
        }
        return values
    }
}

/// The scheduler's hold reasons (`CmuxWallpaperDecision.hold_reason`).
private nonisolated enum HoldReason {
    static let covered: UInt8 = 2
    /// A motion scene at rest.
    static let atRest: UInt8 = 13
    private static let names = ["", "occluded", "covered", "minimized", "app-hidden", "screens-asleep", "session-inactive",
                                "low-power", "thermal", "reduce-motion", "animations-off", "too-heavy", "idle", "at-rest"]

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
