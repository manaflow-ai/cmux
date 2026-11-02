public import AppKit
public import CmuxNextDesign
import CmuxNextTerminalGeometry
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface
import os
import QuartzCore

/// NSView that hosts one Ghostty surface fed by a ``TerminalIO``.
///
/// Ghostty's Metal renderer installs its own `IOSurfaceLayer` as this view's
/// layer (ghostty/src/renderer/Metal.zig); never replace the layer. The
/// surface is created in `init`, like Ghostty.app does, so output that
/// arrives before the view joins a window is not lost, and freed in `deinit`.
///
/// Created and owned by ``TerminalSession``; embed ``TerminalSession/view``,
/// not this view directly.
public final class TerminalSurfaceView: NSView {
    // MARK: State

    private(set) var surface: ghostty_surface_t?
    /// The light/dark scheme last given to this surface (diagnostics).
    var colorSchemeIsDark = false
    let bridge: Unmanaged<SurfaceBridge>
    /// Serial lane for output and other process_output-ordered calls.
    private(set) var lane: TerminalOutputLane?
    weak var session: TerminalSession?

    /// Which grid the surface renders and reports (``TerminalGridPolicy``):
    /// the PTY owner's announced grid once there is one; the view's grid is
    /// only reported.
    private var geometry = TerminalGridPolicy(ownsGeometry: true)

    /// The grid this view's pixel size fits (its last ``updateSurfaceSize(forceReport:)``),
    /// whatever grid the PTY owner announced. Nil before the first layout.
    var fittedGrid: TerminalGridSize? { geometry.desired }

    /// Whether a grid report waits for the pane's layout spring to land (``TerminalGridPolicy/held``).
    var isHeldGridPending: Bool { geometry.held }

    /// A person drags a divider or edge of this terminal's pane (`PaneResizeGestureFollowing`): the view's
    /// grid is held (drawn as the reflow preview) and goes to the PTY once, when the drag lands.
    var isFollowingResizeGesture = false

    /// Reports the grid the pane's layout spring will land at, now (``TerminalGridPolicy/finalSized(_:)``),
    /// unless the owner already has it.
    func reportFinalGrid(_ grid: TerminalGridSize) {
        defer { updateReflowPreview() }
        guard let surface, let report = geometry.finalSized(grid) else { return }
        Self.gridReports &+= 1
        let size = ghostty_surface_size(surface)
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        let cells = metrics.cellPixels(of: report)
        session?.surfaceDidReport(grid: report, pixelWidth: cells.width, pixelHeight: cells.height, final: true)
    }

    /// The pane's layout spring landed: the final grid no longer stands in for the view's, and the surface
    /// takes its host's area again (a landing at another size reports that grid). The reflow preview is
    /// left as it is until the view's next size.
    func endPaneMotion() {
        geometry.motionLanded()
        (superview as? TerminalHostView)?.releaseSurfaceHold()
        if isHeldGridPending { updateSurfaceSize() }
    }

    /// Whether this view reports its grid to the PTY owner. Followers only
    /// render the announced grid (shell.md 2.3).
    var ownsGeometry: Bool {
        get { geometry.ownsGeometry }
        set {
            guard newValue != geometry.ownsGeometry else { return }
            geometry.ownsGeometry = newValue
            updateSurfaceSize(forceReport: true)
        }
    }

    /// App-controlled pause (off-screen strip column, unselected tab).
    var isRenderingSuspended = false {
        didSet { if isRenderingSuspended != oldValue { updateOcclusion() } }
    }

    /// Mirrors attached to this view. While positive the surface keeps
    /// rendering even when hidden, so hover previews stay live.
    var mirrorDemand = 0 {
        didSet { if (mirrorDemand > 0) != (oldValue > 0) { updateOcclusion() } }
    }

    private(set) var lastOcclusionVisible: Bool?
    private(set) var pause: SurfacePause? = .notInWindow // why it does not draw (nil: draws)
    /// The presented frame made volatile while the surface does not draw (`holdPresentedFrame`).
    private var volatileFrame: IOSurface?
    private var lastFocus: Bool?
    private var windowObservers: [any NSObjectProtocol] = []
    private var appliedContentScale: NSSize?
    private var appliedDisplayID: UInt32?
    var trackingArea: NSTrackingArea?
    var cursor: NSCursor = .iBeam

    // Keyboard state (see TerminalSurfaceView+Keyboard.swift).
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    /// A UTF-16 lead surrogate an input method inserted alone (UnicodeHexInput); the next
    /// insertText brings its trail (upstream Ghostty #13737).
    var leadSurrogate: UTF16.CodeUnit?
    var lastPerformKeyEventTimestamp: TimeInterval?
    var previousPressureStage = 0
    /// The left press went to Ghostty as a link click, in a program that has the mouse or with
    /// Shift- or Option-Command (``TerminalPointerMods``): its drags and release go the same way.
    var linkPressInCapture = false

    /// Keyboard copy mode (``TerminalCopyMode``).
    private(set) lazy var copyMode = TerminalCopyMode(view: self)
    /// Ghostty's clipboard reads and confirmations (``TerminalClipboardRequests``).
    private(set) lazy var clipboardRequests = TerminalClipboardRequests(view: self)
    /// Cmd-hover and Cmd-click on links beyond Ghostty's own (``TerminalLinkPointer``).
    private(set) lazy var linkPointer = TerminalLinkPointer(view: self)

    // MARK: Lifecycle

    init(io mode: ghostty_surface_io_mode_e, input: TerminalInputSink, session: TerminalSession?) {
        let bridge = SurfaceBridge(input: input)
        self.bridge = Unmanaged.passRetained(bridge)
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        bridge.view = self
        createSurface(mode: mode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            TerminalSecureInput.release(self)
            guard let surface else {
                bridge.release()
                return
            }
            // The lane frees the surface after its chunk in flight; this never waits for it
            // (``TerminalOutputLane/close(then:)``).
            let teardown = TerminalSurfaceTeardown(surface: surface, bridge: bridge)
            if let lane { lane.close(then: teardown) } else { teardown.run() }
        }
    }

    /// `ghostty_surface_new` with embedder-owned IO (ghostty.h:548-559,
    /// :627-629). `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` for the daemon,
    /// `GHOSTTY_SURFACE_IO_MANUAL` for a bare PTY.
    private func createSurface(mode: ghostty_surface_io_mode_e) {
        let started = ContinuousClock.now
        let signpost = TerminalTimings.signposter.beginInterval("createSurface")
        defer {
            TerminalTimings.signposter.endInterval("createSurface", signpost)
            TerminalTimings.surfaceCreated(started.duration(to: .now))
        }
        guard let app = GhosttyRuntime.shared.app else { return }
        let userdata = bridge.toOpaque()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = userdata
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.io_mode = mode
        config.io_write_cb = ghosttyIOWrite
        config.io_write_userdata = userdata
        guard let surface = ghostty_surface_new(app, &config) else {
            GhosttyRuntime.logger.error("ghostty_surface_new failed")
            return
        }
        self.surface = surface
        // The drawable follows the size this view sets (`setFrameSize`), not
        // its layer's bounds: one synchronous frame per size change at the
        // next display pass, no draw for a bounds change alone.
        ghostty_surface_set_host_sized(surface, true)
        TerminalFontScale(self).installCallback()
        // Light/dark themes (default Apple System Colors) follow the app.
        GhosttyRuntime.shared.registerColorScheme(of: self)
        lane = TerminalOutputLane(surface: surface, label: "com.cmuxterm.next.terminal.output",
                                  frameLayer: layer.map(ObjectIdentifier.init))
        if TypingLatencyProbe.isEnabled, let layer { TypingFrameProbe.install(on: layer) }
        registerForDraggedTypes([.fileURL, .URL, .string])
        updateContentScale()
        updateSurfaceSize(forceReport: true)
        updateOcclusion()
        updateFocus()
    }

    nonisolated public override var isFlipped: Bool { false }

    // MARK: Window, scale, and size

    /// Window notifications reach only a shown terminal: a hidden one (a parked tab or workspace,
    /// still in its window) has no observers, so a key, occlusion or screen change of the window
    /// does no work per hidden terminal. Showing it again catches up (`syncWindowState`).
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        observeWindow(false)
        // Leaving its window gets no mouseExited: the modifier watcher and underlines go here.
        if newWindow == nil { linkPointer.exited() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWindowState()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        isShown = false
        // A hidden terminal gets no mouseExited: its link hover and modifier watcher end here.
        linkPointer.exited()
        observeWindow(false)
        updateOcclusion()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        syncWindowState()
    }

    /// Shown in a window: observe it and apply its current scale, screen, size, occlusion and key
    /// state (each a no-op when unchanged). Parked counts as hidden (``ParkingContainer``).
    private func syncWindowState() {
        let shown = window != nil && !isHiddenOrHasHiddenAncestor && !isParkedOrHasParkedAncestor
        isShown = shown
        observeWindow(shown)
        if !shown { linkPointer.exited() }
        // Out of its window, no drag's end may reach it (its layout root can go before it): it stops following, so
        // its next shown size reports as any other, never held for a drag that is gone.
        if window == nil { isFollowingResizeGesture = false }
        if shown {
            updateContentScale()
            // A view that joins a pane on a layout spring sends the grid the spring rests at, once; its first
            // report (held while it was not shown) would be a size no frame rests at.
            let joined = isInPaneMotion && joinPaneMotion()
            updateSurfaceSize(forceReport: pendingForcedReport && !joined)
            pendingForcedReport = false
        }
        updateOcclusion()
        updateFocus()
    }

    /// Shown in a window, not hidden or parked (``syncWindowState()``). A layout change of a terminal
    /// that is not shown records its size only (PL-script A3: a hidden workspace's layout sized every
    /// warm terminal's surface and resized its PTY); showing it applies the last size once.
    private(set) var isShown = false
    /// A forced grid report asked for while the view was not shown (`TerminalSession.init`, a new owner):
    /// it goes when the view is shown.
    private var pendingForcedReport = false

    private func observeWindow(_ observe: Bool) {
        guard observe == windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for observer in windowObservers { center.removeObserver(observer) }
        windowObservers.removeAll()
        guard observe, let window else { return }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.windowStateChanged(name) } // main-proof: observer on queue: .main
            })
        }
    }

    /// Window notifications handled (`debug.layout_counters`): only shown terminals count.
    public static var windowStateUpdates: UInt64 = 0
    /// Grid reports views made to their session (`debug.window_transition`).
    public static var gridReports: UInt64 = 0

    private func windowStateChanged(_ name: Notification.Name) {
        Self.windowStateUpdates &+= 1
        switch name {
        case NSWindow.didChangeOcclusionStateNotification:
            updateOcclusion()
        case NSWindow.didChangeScreenNotification:
            updateContentScale()
            updateSurfaceSize()
        default:
            updateFocus()
        }
    }

    /// AppKit walks hidden views too; a hidden terminal applies the scale when shown.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !isHiddenOrHasHiddenAncestor else { return }
        updateContentScale()
        updateSurfaceSize()
    }

    /// Every frame of a drag resizes a shown surface at once (a hidden one waits to be shown,
    /// ``syncWindowState()``): the drawable takes
    /// the new size and draws one frame with the text reflowed to it (the
    /// reflow preview, ``updateReflowPreview()``), and the grid report goes to
    /// the owner through `ResizeCoordinator` (next frame, one in flight). The
    /// owner's announcement then shows the same rows.
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized, isShown { updateSurfaceSize() }
        copyMode.syncCursor()
    }

    /// `ghostty_surface_set_content_scale` + `ghostty_surface_set_display_id`
    /// (ghostty.h:1440, :1821).
    /// Applies only what changed since the last call (a terminal shown again calls it).
    private func updateContentScale() {
        guard let surface else { return }
        let scale = convertToBacking(NSSize(width: 1, height: 1))
        if scale != appliedContentScale {
            appliedContentScale = scale
            ghostty_surface_set_content_scale(surface, scale.width, scale.height)
        }
        if let window {
            if layer?.contentsScale != window.backingScaleFactor {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }
            if let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               screenNumber.uint32Value != appliedDisplayID {
                appliedDisplayID = screenNumber.uint32Value
                ghostty_surface_set_display_id(surface, screenNumber.uint32Value)
            }
        }
    }

    /// Locks the mirror to the owner's grid on the output lane, behind every
    /// earlier chunk (`ghostty_surface_set_grid`), at the owner's point in the
    /// byte stream. `restored`: a local-history restore resizes the terminal
    /// itself, so only the lock's record follows (no set_grid).
    func applyAnnouncedGrid(_ grid: TerminalGridSize, restored: Bool = false) {
        geometry.announce(grid)
        if restored { gridLock.adopt(grid) } else { lockAnnouncedGrid() }
        updateSurfaceSize()
    }

    /// Sends the announced grid to Ghostty in stream order (``TerminalGridLock``).
    private var gridLock = TerminalGridLock()

    private func lockAnnouncedGrid() {
        guard let grid = geometry.gridToRender, let lane else { return }
        gridLock.lock(grid, on: lane)
    }

    /// Whether the surface draws its reflow preview: only a view whose
    /// reported grid the owner applies (``TerminalIO/appliesViewGrid``).
    private var reflowPreview = false

    /// Turns the reflow preview on while the owner applies this view's grid.
    /// Until the owner announces the view's grid, Ghostty draws the locked
    /// grid reflowed to the view's grid (render only); a view whose grid the
    /// owner does not apply draws the locked grid, cropped or padded.
    /// `reporting`: this call reports a new grid to the owner.
    func updateReflowPreview(reporting: Bool = false) {
        guard let surface else { return }
        let enabled = geometry.ownsGeometry && geometry.previewsViewGrid
            && (session?.io.appliesViewGrid(reporting: reporting) ?? false)
        guard enabled != reflowPreview else { return }
        reflowPreview = enabled
        ghostty_surface_set_reflow_preview(surface, enabled)
    }

    /// Sizes the surface to the view and reports the view's grid when it
    /// changed.
    ///
    /// The view's pixel size always goes to `ghostty_surface_set_size`, and
    /// `ghostty_surface_size` reports how many cells fit. Before any
    /// announcement that is also the terminal grid. After one, the terminal
    /// grid is locked to the announced grid (`ghostty_surface_set_grid`):
    /// a larger view draws padding, a smaller one crops, and the report still
    /// says what would fit. The owner decides; the surface follows its
    /// announcement.
    func updateSurfaceSize(forceReport: Bool = false) {
        guard let surface else { return }
        // Not shown (made, hidden or parked): no size and no report now; the view sizes and reports once it
        // is shown (`syncWindowState`), a forced report included.
        guard isShown else {
            pendingForcedReport = pendingForcedReport || forceReport
            return
        }
        let pixels = convertToBacking(bounds.size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        defer { copyMode.syncCursor() }
        ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
        let size = ghostty_surface_size(surface)
        publish(size: size)
        guard size.columns > 0, size.rows > 0 else { return }
        let desired = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        // A pane on a layout spring (Cmd-Shift-Enter zoom, split, close) resizes this view on every
        // display frame: the surface draws each size (the reflow preview), and the grid goes to the
        // owner once the spring lands (`paneMotionDidSettle`), one PTY resize instead of one per frame.
        let report = geometry.viewSized(desired, force: forceReport, holding: !forceReport && (isInPaneMotion || isFollowingResizeGesture))
        // In the same main-thread turn as set_size: the frame of the new size
        // draws at the next display pass, already reflowed.
        // A held grid is reported when the spring lands: the preview draws it meanwhile.
        updateReflowPreview(reporting: report != nil || geometry.held)
        guard let report else { return }
        Self.gridReports &+= 1
        let cells = metrics.cellPixels(of: report)
        session?.surfaceDidReport(grid: report, pixelWidth: cells.width, pixelHeight: cells.height)
    }

    private func publish(size: ghostty_surface_size_s) {
        guard let model = session?.model else { return }
        let grid = geometry.gridToRender ?? TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        if model.grid != grid { model.grid = grid }
        let cell = CGSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px))
        if model.cellPixelSize != cell { model.cellPixelSize = cell }
    }

    /// A rough app-side memory cost of this surface for the resource hover
    /// card: its drawable (three BGRA buffers) plus the GPU cell buffers
    /// (about 64 bytes per cell). Ghostty does not report its own
    /// allocations (font atlas, parser state), so this is a lower bound.
    public var memoryEstimateBytes: UInt64 {
        guard let surface else { return 0 }
        let size = ghostty_surface_size(surface)
        let pixels = UInt64(size.width_px) * UInt64(size.height_px)
        let cells = UInt64(size.columns) * UInt64(size.rows)
        return pixels * 4 * 3 + cells * 64
    }

    /// Whether the terminal is currently using Ghostty's alternate screen.
    /// Full-screen programs such as vim, less and tmux use this screen; the
    /// key router reads it when evaluating `shortcuts.when` predicates.
    public var isAlternateScreen: Bool {
        guard let surface else { return false }
        var metrics = ghostty_surface_grid_metrics_s()
        return ghostty_surface_grid_metrics(surface, &metrics) && metrics.alternate_screen
    }

    /// The grid the surface renders now: the locked grid, or what fits the
    /// view before a lock.
    var currentGrid: TerminalGridSize? {
        guard let surface else { return nil }
        let grid = ghostty_surface_grid(surface)
        if grid.locked { return TerminalGridSize(columns: Int(grid.columns), rows: Int(grid.rows)) }
        let size = ghostty_surface_size(surface)
        return TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
    }

    /// Cell size in points, for IME rectangles.
    var cellPointSize: CGSize {
        guard let surface else { return CGSize(width: 8, height: 16) }
        let size = ghostty_surface_size(surface)
        let backing = convertFromBacking(NSSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px)))
        return CGSize(width: max(backing.width, 1), height: max(backing.height, 1))
    }

    // MARK: Occlusion

    /// `ghostty_surface_set_occlusion` (ghostty.h:1442) per ``WindowDrawPolicy``. Paused surfaces
    /// keep parsing output; Ghostty draws the current content on its `.visible` message.
    func updateOcclusion() {
        guard let surface else { return }
        pause = WindowDrawPolicy.inputs(for: self, suspended: isRenderingSuspended, forced: mirrorDemand > 0).pause
        let drawing = pause == nil
        guard drawing != lastOcclusionVisible else { return }
        lastOcclusionVisible = drawing
        holdPresentedFrame(volatile: pause != nil)
        ghostty_surface_set_occlusion(surface, drawing)
        // A surface can parse a renderer-affecting OSC action (for example Copilot's OSC 11
        // background update) before its view has ever joined a window. The visibility message
        // normally starts the next frame, but a first display after that off-window parse can
        // otherwise retain an empty IOSurface. Explicitly refresh the reveal edge so the state
        // already parsed off-screen is presented (#22282, related to #16706/#18432).
        if drawing { ghostty_surface_refresh(surface) }
    }

    /// A paused surface keeps the frame its layer shows, volatile until it shows again
    /// (``TerminalFramePurgeability``): shown again, it is non-volatile before the next commit, and a
    /// purged one leaves the layer empty until Ghostty's next frame, as before.
    private func holdPresentedFrame(volatile: Bool) {
        if volatile {
            volatileFrame = presentedFrame
            volatileFrame?.makeVolatile()
        } else if let frame = volatileFrame {
            volatileFrame = nil
            // A frame in flight at the pause may have replaced it: that one is not volatile.
            guard presentedFrame === frame else { return }
            if !frame.reclaim() { layer?.contents = nil }
        }
    }

    /// The presented frame for one reader (hover pictures): a paused surface's volatile frame is
    /// made non-volatile for the read (nil when purged); ``endFrameRead(_:)`` makes it volatile again.
    func beginFrameRead() -> IOSurface? {
        guard let frame = presentedFrame else { return nil }
        guard frame === volatileFrame else { return frame }
        guard frame.reclaim() else {
            volatileFrame = nil
            layer?.contents = nil
            return nil
        }
        return frame
    }

    func endFrameRead(_ frame: IOSurface) {
        if frame === volatileFrame { frame.makeVolatile() }
    }

    // MARK: Focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateFocus(firstResponder: true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { updateFocus(firstResponder: false) }
        return accepted
    }

    var isFirstResponder: Bool { window?.firstResponder === self }

    /// Focus is first responder in the key window. Ghostty uses it for cursor
    /// style and for focus reports (mode 1004) to the program.
    private func updateFocus(firstResponder: Bool? = nil) {
        guard let surface else { return }
        let focused = (firstResponder ?? isFirstResponder) && (window?.isKeyWindow ?? false)
        guard focused != lastFocus else { return }
        lastFocus = focused
        ghostty_surface_set_focus(surface, focused)
        session?.model.isFocused = focused
        if focused { session?.surfaceDidGainFocus() }
    }

    // MARK: Binding actions

    /// Runs a Ghostty binding action such as `copy_to_clipboard` or
    /// `search:foo` (ghostty.h:1665).
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return clipboardRequests.asUserClipboardWrite {
            action.withCString { pointer in
                ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }
}

/// A workspace parked without hiding pauses this surface and drops its window observers, as hiding
/// does; shown again it catches up (`syncWindowState`).
extension TerminalSurfaceView: ParkingObserver {
    public func parkingDidChange() { syncWindowState() }
}
