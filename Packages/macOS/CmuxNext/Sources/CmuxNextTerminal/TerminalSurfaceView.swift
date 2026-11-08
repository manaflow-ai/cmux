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

    /// The pixel size last given to `ghostty_surface_set_size` (``setSurfacePixels(_:on:)``).
    private var lastSurfacePixels: (width: UInt32, height: UInt32)?

    /// Which grid the surface renders and reports (``TerminalGridPolicy``):
    /// the PTY owner's announced grid once there is one; the view's grid is
    /// only reported.
    private var geometry = TerminalGridPolicy(ownsGeometry: true)

    /// The grid this view's pixel size fits (its last ``updateSurfaceSize(forceReport:)``),
    /// whatever grid the PTY owner announced. Nil before the first layout.
    var fittedGrid: TerminalGridSize? { geometry.desired }

    /// Whether a grid report waits for the pane's layout spring to land (``TerminalGridPolicy/held``).
    var isHeldGridPending: Bool { geometry.held }

    /// Whether a grid report waits: held for a spring's landing, or in the coalescer's window (to the next refresh).
    var isGridReportPending: Bool { geometry.held || gridReports.isWaiting }

    /// Hidden, closed or detached from its session: the grid that waits in the coalescer's window goes nowhere. Only if
    /// that grid is not the PTY's (`lastSent`), the view sends its grid when shown again, as any grid at rest (the
    /// coalescer skips one equal to the PTY's): a hide and show with nothing dropped sends nothing, so a tab switch never
    /// resizes the PTY for nothing (``resendsShownGrid``).
    func cancelGridReport() {
        let coalescer = gridReports.coalescer
        guard let dropped = coalescer.pending else { return }
        coalescer.cancel()
        if dropped != coalescer.lastSent { resendsShownGrid = true }
    }

    /// A grid the PTY does not have was dropped with a hide (``cancelGridReport()``): shown again, the view's grid goes.
    var resendsShownGrid = false

    /// Who presents this view's new sizes and a held display scale (``place(_:)``).
    var frameOwnership = TerminalFrameOwnership()

    /// A person drags a divider or edge of this terminal's pane (its host's ``TerminalHostView/followsResizeGesture``): the
    /// surface follows its pane in every frame, and its grids go to the PTY coalesced (``gridReports``, cmux-ad m29).
    var isFollowingResizeGesture = false
    /// Every grid report to the PTY owner: a drag's coalesced, every other one now.
    lazy var gridReports = TerminalGridReporter(view: self)

    /// Reports the grid the pane's layout spring will land at, now (``TerminalGridPolicy/finalSized(_:)``),
    /// unless the owner already has it.
    func reportFinalGrid(_ grid: TerminalGridSize) {
        defer { updateReflowPreview() }
        guard surface != nil, let report = geometry.finalSized(grid) else { return }
        gridReports.now(report)
    }

    /// The pane's layout spring landed: the final grid no longer stands in for the view's, and the surface
    /// takes its host's area again (a landing at another size reports that grid). The reflow preview is
    /// left as it is until the view's next size.
    func endPaneMotion() {
        geometry.motionLanded()
        (superview as? TerminalHostView)?.releaseSurfaceHold()
        if isHeldGridPending { updateSurfaceSize() }
        resendShownGrid(atRest: true)
        // A key resize's last grid goes at its landing, not at the next refresh.
        gridReports.flush()
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
    /// ``showsForLaunchFrame`` at the last ``updateOcclusion()``.
    private var lastShowsForLaunchFrame = false

    /// Whether the launch-frame keeper counts this terminal as on screen: in a window that is ordered in, not hidden,
    /// parked or suspended. A covered window still counts (it shows again at a relaunch); forced drawing (a hover
    /// mirror) does not make a hidden terminal count.
    var showsForLaunchFrame: Bool {
        Self.showsForLaunchFrame(WindowDrawPolicy.inputs(for: self, suspended: isRenderingSuspended), window: window)
    }

    static func showsForLaunchFrame(_ inputs: SurfaceDrawInputs, window: NSWindow?) -> Bool {
        inputs.inWindow && !inputs.hidden && !inputs.parked && !inputs.suspended && window?.isVisible == true
    }
    private(set) var pause: SurfacePause? = .notInWindow // why it does not draw (nil: draws)
    /// The presented frame made volatile while the surface does not draw (`holdPresentedFrame`).
    private var volatileFrame: IOSurface?
    /// A frame another view shows now (``giveAway(_:)``): never made volatile here again.
    private var givenAwayFrame: IOSurface?
    private var lastFocus: Bool?
    private var windowObservers: [any NSObjectProtocol] = []
    /// The display scale last given to Ghostty (``updateContentScale()``); nil before it was set.
    private(set) var appliedContentScale: NSSize?
    private var appliedDisplayID: UInt32?
    /// The display scale a test puts this view at (its window moved to a display of another scale); nil: AppKit's.
    var backingScaleOverride: CGFloat?
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

    /// `prediction`: the session's predictive echo engine, fed this surface's input and parsed output.
    init(io mode: ghostty_surface_io_mode_e, input: TerminalInputSink, session: TerminalSession?,
         prediction: TerminalEchoPrediction? = nil) {
        let bridge = SurfaceBridge(input: input, prediction: prediction)
        self.bridge = Unmanaged.passRetained(bridge)
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        bridge.view = self
        createSurface(mode: mode)
        #if DEBUG || CMUX_BENCH_HOOKS
        _ = Self.motionSamplerRegistration
        #endif
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
        // Its window's commit presents every new size (FRAME OWNER S4; cmux-ad m19: no switch).
        ownFramesByCommit()
        TerminalFontScale(self).installCallback()
        // Light/dark themes (default Apple System Colors) follow the app.
        GhosttyRuntime.shared.registerColorScheme(of: self)
        lane = TerminalOutputLane(surface: surface, label: "com.cmuxterm.next.terminal.output",
                                  frameLayer: layer.map(ObjectIdentifier.init), prediction: bridge.takeUnretainedValue().prediction)
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
    /// A surface follows its host's drag, one swapped in during the drag too (a replay); leaving its host, it stops, while
    /// it is still in its window (its superview is already gone by `viewDidMoveToWindow`).
    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { isFollowingResizeGesture = (newSuperview as? TerminalHostView)?.followsResizeGesture == true }
        super.viewWillMove(toSuperview: newSuperview)
    }

    /// Stops following a resize drag that will not end for this view: its waiting grid goes now, its next size as any other.
    func stopFollowingResizeGesture() {
        isFollowingResizeGesture = false
        gridReports.flush()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A size that waits for this window's commit takes its bounds now.
        if newWindow !== window { releaseFrameOwnership() }
        super.viewWillMove(toWindow: newWindow)
        observeWindow(false)
        // Leaving its window gets no mouseExited: the modifier watcher and underlines go here.
        if newWindow == nil { linkPointer.exited() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPointerTracking() // a pane's screen serves it, or it tracks the pointer itself (TerminalSurfaceView+Mouse)
        syncWindowState()
        // In another window, its last shown-size change's commit is reported by that window's presenter.
        frameOwnershipDidReveal()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        isShown = false
        cancelGridReport()
        dropAheadForHide()
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
        if !shown {
            linkPointer.exited()
            cancelGridReport()
            dropAheadForHide()
        }
        // Out of its window, no drag's end may reach it (its layout root can go before it): it stops following, so
        // its next shown size reports as any other, never held for a drag that is gone.
        if window == nil { stopFollowingResizeGesture() }
        if shown {
            updateContentScale()
            // A view that joins a pane on a layout spring sends the grid the spring rests at, once; its first
            // report (held while it was not shown) would be a size no frame rests at.
            let joined = isInPaneMotion && joinPaneMotion()
            updateSurfaceSize(forceReport: pendingForcedReport && !joined, justShown: true)
            pendingForcedReport = false
            // A join sent the grid its spring rests at; else a grid a hide dropped goes (``resendShownGrid(atRest:)``).
            if joined { resendsShownGrid = false } else { resendShownGrid(atRest: !isInPaneMotion && !isFollowingResizeGesture) }
            requestPresentIfNeeded()
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
            backingDidChange()
        default:
            updateFocus()
        }
    }

    /// AppKit walks hidden views too; a hidden terminal applies the scale when shown.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !isHiddenOrHasHiddenAncestor else { return }
        backingDidChange()
    }

    /// A new display scale or screen: Ghostty's scale and pixel size follow at once; while its window's commit owns
    /// the frame, the layer takes the new scale with the frame drawn at it (``requestPresentIfNeeded()``).
    private func backingDidChange() {
        updateContentScale()
        updateSurfaceSize()
        requestPresentIfNeeded()
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
        if resized { session?.frameChanges.bump() } // its kept frame has another size now (TerminalLaunchFrameKeeper)
        // Taking the size Ghostty already shows (``landRequestedFrame()``) asks for no new size.
        if resized, isShown, !frameOwnership.landing { updateSurfaceSize() }
        // A landing runs under the Core Animation lock: its cursor box follows after it (``frameDidLand()``).
        if !frameOwnership.landing { copyMode.syncCursor() }
    }

    /// `ghostty_surface_set_content_scale` + `ghostty_surface_set_display_id`
    /// (ghostty.h:1440, :1821).
    /// Applies only what changed since the last call (a terminal shown again calls it).
    private func updateContentScale() {
        guard let surface else { return }
        let scale = toBacking(NSSize(width: 1, height: 1))
        if scale != appliedContentScale {
            appliedContentScale = scale
            ghostty_surface_set_content_scale(surface, scale.width, scale.height)
            // A new scale: the next size goes to Ghostty even at the same pixel size.
            lastSurfacePixels = nil
        }
        if let window {
            let backing = backingScaleOverride ?? window.backingScaleFactor
            // While its window's commit owns the frame, the layer keeps the scale of the frame it shows.
            if !holdsScale(backing), layer?.contentsScale != backing {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer?.contentsScale = backing
                CATransaction.commit()
            }
            if let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               screenNumber.uint32Value != appliedDisplayID {
                appliedDisplayID = screenNumber.uint32Value
                ghostty_surface_set_display_id(surface, screenNumber.uint32Value)
            }
        }
    }

    /// `size` in this view's backing pixels: AppKit's conversion, or ``backingScaleOverride``'s.
    private func toBacking(_ size: NSSize) -> NSSize {
        guard let scale = backingScaleOverride else { return convertToBacking(size) }
        return NSSize(width: size.width * scale, height: size.height * scale)
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
    /// owner does not apply draws the locked grid, cropped or padded. In a key
    /// resize whose host follows its pane, it stays on in every frame (``TerminalGridPolicy/previewsViewGrid(followingPane:)``).
    /// `reporting`: this call reports a new grid to the owner.
    func updateReflowPreview(reporting: Bool = false) { // perf-hot: 1ms motion-frame (each frame of a key resize)
        guard let surface else { return }
        let followingPane = (superview as? TerminalHostView)?.surfaceFollowsArea ?? false
        let enabled = geometry.ownsGeometry && geometry.previewsViewGrid(followingPane: followingPane)
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
    /// - Parameter justShown: The view was just shown (``syncWindowState()``): its bounds can be the ones it had out of its
    ///   pane (a new terminal's 800x600 init frame), and the pane's layout gives it its frame later in this turn. In a key
    ///   spring (a tab switch mid-hold) the grid of these bounds then waits for the refresh, and the layout's grid replaces it;
    ///   sent at once (RESIZE P0 7's first grid of a refresh), it reached the PTY as a grid its pane never showed (RESIZE P0
    ///   8, item 0: a tab switch mid-hold sent 99x34, then 80x44).
    /// - Parameter drawingAhead: The call gives Ghostty a size drawn ahead (``applyAhead()``): the shown frame did not
    ///   change, so the copy-mode cursor box stays.
    /// - Parameter replacingAhead: That size replaces a size drawn ahead whose frame will not show (a key press retargeted
    ///   the spring): its grid goes at once (``TerminalGridReporter/coalesced(_:waitsForRefresh:replacesUnshown:)``).
    func updateSurfaceSize(forceReport: Bool = false, justShown: Bool = false, drawingAhead: Bool = false,
                           replacingAhead: Bool = false) {
        guard let surface else { return }
        // Not shown (made, hidden or parked): no size and no report now; the view sizes and reports once it
        // is shown (`syncWindowState`), a forced report included.
        guard isShown else {
            pendingForcedReport = pendingForcedReport || forceReport
            return
        }
        // The size asked of Ghostty and not shown yet, else the size drawn ahead for the next refresh (a call here must
        // not take Ghostty back to the shown size and drop that frame), else the view's (``place(_:anchor:)``).
        let pixels = toBacking(frameOwnership.inFlight ?? frameOwnership.ahead ?? bounds.size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        defer { if !drawingAhead { copyMode.syncCursor() } }
        setSurfacePixels(pixels, on: surface)
        let size = ghostty_surface_size(surface)
        // The PTY's grid. In a key resize it is the grid of the size asked of Ghostty (`inFlight`, else the size drawn
        // ahead for the next refresh, `ahead`): RESIZE P0 11, cause E (Lawrence m55, "terminals: zero lag"). Chromium
        // sends a renderer its new size before the compositor needs the frame, and shows that size with the frame the
        // renderer drew for it; the program is the renderer of a terminal's contents, so it gets the grid before the pass
        // that presents the frame, and redraws at it in the refresh between (its output parsed about 3.5 ms after the
        // send, a 120 Hz refresh is 8.3 ms). Sent only when the size showed (STATUS 14461), the program redrew after its
        // frame was on screen, and every drawn-ahead frame showed the program's picture of the previous grid, clipped or
        // banded at the new edge (diag 2b50b18e, cmux21, macOS 26, 1x 120 Hz, px-keys-held-2-s1r: 35 of 37 judged edge
        // frames). A retarget can leave one such grid unshown; the next refresh sends the grid it asks for. Elsewhere it
        // is the grid the view's committed bounds fit (a drag's goes once its size shows; a split's, close's or zoom's
        // spring holds its grid to the landing), and the landing calls this again with the new bounds (``frameDidLand()``).
        let keyResize = followsKeyResize
        let reported = keyResize ? Self.grid(fitting: size) : shownGrid(on: surface, fallback: size)
        guard let desired = reported else { return publish(size: size, grid: nil) }
        publish(size: size, grid: desired)
        // A pane on a layout spring (Cmd-Shift-Enter zoom, split, close) resizes this view on every display
        // frame: the surface draws each size (the reflow preview), and the grid goes to the owner once the
        // spring lands (`paneMotionDidSettle`), one PTY resize instead of one per frame. A key resize whose host
        // follows its pane (cmux-ad m18) and a drag (its release's spring too, cmux-ad m29) are live instead: their
        // grids go coalesced (``TerminalGridReporter``), at most once per refresh (the first at once, RESIZE P0 7), ending at the landing's.
        let live = keyResize || isFollowingResizeGesture
        // A size whose frame is not drawn yet and is no longer the one wanted (FRAME OWNER S4: the pane
        // moved on, or its spring landed, while the frame waited) reports nothing: the wanted size
        // reports its grid when its frame lands. The landing's release sized from such a size and sent its stale grid,
        // then the final grid again (review of #35470, F1).
        let stale = frameOwnership.inFlight.map { $0 != frameOwnership.wanted?.size } ?? false
        let report = geometry.viewSized(desired, force: forceReport,
                                        holding: stale || (!forceReport && isInPaneMotion && !live))
        // In the same main-thread turn as set_size: the frame of the new size draws at the next display pass, already
        // reflowed. A held or coalesced grid is reported later: the preview draws it meanwhile.
        updateReflowPreview(reporting: report != nil || geometry.held || gridReports.isWaiting)
        guard let report else {
            // At rest at the grid that waits in the coalescer's window (a gesture ended there): it goes now.
            if !live { gridReports.flush() }
            return
        }
        if forceReport || !live {
            gridReports.now(report)
        } else if isFollowingResizeGesture {
            // A drag's grid goes once its size shows: now with the bounds, or when the presenter shows it (`frameDidLand`).
            gridReports.drag(report, shownNow: frameOwnership.inFlight == nil)
        } else {
            // A key spring's grid: the size asked of Ghostty, coalesced; a just-shown view's waits for the refresh.
            gridReports.coalesced(report, waitsForRefresh: justShown, replacesUnshown: replacingAhead)
        }
    }

    /// Whether a key resize drives this view's size (``updateSurfaceSize(forceReport:justShown:drawingAhead:)``): its host
    /// follows its pane's key hold, or the key's turn drew the press's first size ahead or the hold's end asked its final
    /// size (``TerminalHostView`` `aheadOfKeyResize`, never a snapped split's, close's or zoom's) and that size is with
    /// Ghostty. A drag that began meanwhile keeps its own rule (its grid goes when its size shows).
    private var followsKeyResize: Bool {
        guard !isFollowingResizeGesture, let host = superview as? TerminalHostView else { return false }
        return host.surfaceFollowsArea
            || (host.aheadOfKeyResize && (frameOwnership.ahead != nil || frameOwnership.inFlight != nil))
    }

    /// The grid Ghostty fits to the size it was given; nil when no whole cell fits.
    private static func grid(fitting size: ghostty_surface_size_s) -> TerminalGridSize? {
        size.columns > 0 && size.rows > 0 ? TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows)) : nil
    }

    /// `ghostty_surface_set_size`, unless Ghostty already has `pixels` (the size a landing shows, the size drawn ahead): a
    /// second call at the same size would drop the frame Ghostty drew for it.
    func setSurfacePixels(_ pixels: NSSize, on surface: ghostty_surface_t) {
        let size = (width: UInt32(pixels.width), height: UInt32(pixels.height))
        guard lastSurfacePixels?.width != size.width || lastSurfacePixels?.height != size.height else { return }
        lastSurfacePixels = size
        ghostty_surface_set_size(surface, size.width, size.height)
    }

    /// The grid the view's committed bounds fit (`ghostty_surface_fit_grid` of their pixel size), or `fallback`'s grid when
    /// the bounds are the size Ghostty has; nil when no whole cell fits.
    private func shownGrid(on surface: ghostty_surface_t, fallback size: ghostty_surface_size_s) -> TerminalGridSize? {
        let shown = toBacking(bounds.size)
        let asked = toBacking(frameOwnership.inFlight ?? frameOwnership.ahead ?? bounds.size)
        if shown == asked { return Self.grid(fitting: size) }
        var columns: UInt16 = 0, rows: UInt16 = 0
        guard shown.width >= 1, shown.height >= 1,
              ghostty_surface_fit_grid(surface, UInt32(shown.width), UInt32(shown.height), &columns, &rows),
              columns > 0, rows > 0 else { return nil }
        return TerminalGridSize(columns: Int(columns), rows: Int(rows))
    }

    /// The model's grid: the owner's announced grid, else `shown` (the grid the committed bounds fit).
    private func publish(size: ghostty_surface_size_s, grid shown: TerminalGridSize?) {
        guard let model = session?.model else { return }
        if let grid = geometry.gridToRender ?? shown, model.grid != grid { model.grid = grid }
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
        let inputs = WindowDrawPolicy.inputs(for: self, suspended: isRenderingSuspended, forced: mirrorDemand > 0)
        pause = inputs.pause
        // The keeper's own "on screen" (``showsForLaunchFrame``) can change while drawing does not (a hover mirror
        // forces drawing; an automation launch draws occluded windows): it is told of either change.
        let shows = Self.showsForLaunchFrame(inputs, window: window)
        if shows != lastShowsForLaunchFrame {
            lastShowsForLaunchFrame = shows
            session?.frameChanges.wake()
        }
        let drawing = pause == nil
        guard drawing != lastOcclusionVisible else { return }
        lastOcclusionVisible = drawing
        session?.frameChanges.wake() // drawn or paused (a window shown, minimized, occluded): its kept frame follows
        let saved = holdPresentedFrame(volatile: pause != nil)
        ghostty_surface_set_occlusion(surface, drawing)
        // A surface can parse a renderer-affecting OSC action (for example Copilot's OSC 11
        // background update) before its view has ever joined a window. The visibility message
        // normally starts the next frame, but a first display after that off-window parse can
        // otherwise retain an empty IOSurface. Explicitly refresh the reveal edge so the state
        // already parsed off-screen is presented (#22282, related to #16706/#18432).
        if drawing {
            ghostty_surface_refresh(surface)
            frameOwnershipDidReveal()
            if isShown { session?.surfaceRevealed(self, saved: saved) }
        } else {
            session?.surfaceHidden(self)
        }
    }

    /// A paused surface keeps the frame its layer shows, volatile until it shows again
    /// (``TerminalFramePurgeability``): shown again, it is non-volatile before the next commit, and a
    /// purged one leaves the layer empty until Ghostty's next frame, as before.
    /// Returns what became of the kept frame when the surface draws again (``TerminalRevealReport/SavedFrame``).
    @discardableResult
    private func holdPresentedFrame(volatile: Bool) -> TerminalRevealReport.SavedFrame {
        if volatile {
            volatileFrame = presentedFrame === givenAwayFrame ? nil : presentedFrame
            volatileFrame?.makeVolatile()
            return .none
        }
        guard let frame = volatileFrame else { return .none }
        volatileFrame = nil
        // A frame in flight at the pause may have replaced it: that one is not volatile.
        guard presentedFrame === frame else { return .replaced }
        guard frame.reclaim() else {
            layer?.contents = nil
            return .purged
        }
        return .kept
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

    /// `frame` is shown by another view from now on (a replacement session's carried frame): this
    /// surface, paused or closed, must not mark it volatile under that view.
    func giveAway(_ frame: IOSurface) {
        givenAwayFrame = frame
        if volatileFrame === frame { volatileFrame = nil }
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
