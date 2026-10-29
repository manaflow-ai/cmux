public import AppKit
public import CmuxNextDesign
public import CmuxNextInput
import CmuxNextTerminalGeometry
import CmuxNextTrace
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
public final class TerminalSurfaceView: NSView, KeyEquivalentOwningSurface {
    // MARK: State

    /// SAFETY: the view's live surface: made in `init`, freed only in `deinit`, and never
    /// replaced, so a non-nil read on the main actor is a live handle for that turn. Off-main
    /// work reaches it only through ``lane``, which `deinit` closes before the free.
    @safe private(set) var surface: ghostty_surface_t?
    /// The light/dark scheme last given to this surface (diagnostics).
    var colorSchemeIsDark = false
    /// SAFETY: +1 from `init` until `deinit` releases it after ghostty_surface_free, so the
    /// userdata Ghostty holds (``SurfaceBridge/from(_:)``) stays a live object for every callback.
    @safe let bridge: Unmanaged<SurfaceBridge>
    /// The bridge, kept alive by the view's retain (`bridge`).
    var bridgeObject: SurfaceBridge {
        // SAFETY: as `bridge`'s note.
        unsafe bridge.takeUnretainedValue()
    }
    /// Serial lane for output and other process_output-ordered calls.
    private(set) var lane: TerminalOutputLane?
    /// Watches each output chunk's parse on ``lane`` (``TerminalOutputLane``); nil watches nothing.
    private let hangWatch: (any HangWatchScoping)?
    /// ``lane`` parses at utility while the view is suspended (``TerminalOutputLane/lowersHidden``).
    private let lowersHiddenOutput: Bool
    /// Where Ghostty's secure keyboard entry requests for this view go (``TerminalSecureInput``).
    let secureInput: TerminalSecureInput
    weak var session: TerminalSession?

    /// Which grid the surface renders and reports (``TerminalGridPolicy``):
    /// the PTY owner's announced grid once there is one; the view's grid is
    /// only reported.
    private(set) var geometry = TerminalGridPolicy(ownsGeometry: true)

    /// The grid this view's pixel size fits (its last ``updateSurfaceSize()``),
    /// whatever grid the PTY owner announced. Nil before the first layout.
    var fittedGrid: TerminalGridSize? { geometry.desired }

    /// Whether a grid report waits for the pane's layout spring to land (``TerminalGridPolicy/held``).
    var isHeldGridPending: Bool { geometry.held }

    /// Reports the grid the pane's layout spring will land at, now (``TerminalGridPolicy/finalSized(_:)``),
    /// unless the owner already has it.
    func reportFinalGrid(_ grid: TerminalGridSize) {
        defer { updateReflowPreview() }
        guard let surface, let report = geometry.finalSized(grid) else { return }
        Self.gridReports &+= 1
        // SAFETY: the view's live surface (`surface`).
        let size = unsafe ghostty_surface_size(surface)
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
            reportToNewOwner()
        }
    }

    /// App-controlled pause (off-screen strip column, unselected tab).
    var isRenderingSuspended = false {
        didSet {
            guard isRenderingSuspended != oldValue else { return }
            lane?.setHidden(isRenderingSuspended) // a hidden surface parses at utility
            updateOcclusion()
        }
    }

    /// Mirrors attached to this view. While positive the surface keeps
    /// rendering even when hidden, so hover previews stay live.
    var mirrorDemand = 0 {
        didSet { if (mirrorDemand > 0) != (oldValue > 0) { updateOcclusion() } }
    }

    /// Its session's frame hold covers it and the content the hold waits for is not parsed yet
    /// (``TerminalFrameHold``, ``SurfacePause/awaitingContent``): the renderer draws nothing until then, so the
    /// first frame it presents after this turns false holds that content.
    var awaitsContent = false {
        didSet { if awaitsContent != oldValue { updateOcclusion() } }
    }

    var lastOcclusionVisible: Bool?
    #if DEBUG || CMUX_BENCH_HOOKS
    /// When the pause last ended and the layer's next frame after it (`debug.surfaces` `show`); record only.
    /// Its gate is the one every terminal layer's hook reads (``TypingFrameProbe``).
    let showRecord: TerminalShowRecord
    #endif
    /// When the paused surface lets its GPU memory go (``TerminalGPUResidencyGate``).
    var gpu: TerminalGPUResidencyGate
    /// Away, outside the keep-alive band: paused, the surface lets its GPU memory go.
    var releasesGPUWhilePaused = false {
        didSet { if releasesGPUWhilePaused != oldValue { updateOcclusion() } }
    }
    /// Shown in a window that stays off screen, the surface lets its GPU memory go (``TerminalOffScreenRelease``).
    var offScreenRelease: TerminalOffScreenRelease
    /// Why the surface does not draw (nil: draws). Only a surface that draws holds a vsync subscription.
    var pause: SurfacePause? = .notInWindow {
        didSet { if pause != oldValue { followVSync() } }
    }
    /// The presented frame kept volatile while the surface does not draw.
    var heldFrame = TerminalHeldFrame()
    private var lastFocus: Bool?
    /// Its window's notices while shown, by its tab node (``TerminalWindowWatch``).
    private let windowWatch: TerminalWindowWatch
    /// Its window's node (AppKit's state and the window's occlusion family), while shown: each flip computes the
    /// pause again (TerminalSurfaceView+Occlusion.swift).
    private var windowNodeWatch: VisibilitySubscription?
    /// The backing scale and display last given to the surface (`updateContentScale`).
    private var appliedBacking = TerminalContentScale()
    /// The display ID last given to the surface (`updateContentScale`); nil before it is first shown.
    var appliedDisplayID: UInt32? { appliedBacking.appliedDisplayID }
    /// Paces the surface from its display's ``VSyncHub`` thread while it draws (``TerminalVSync``). The bridge
    /// owns it, so it lives as long as the userdata Ghostty's `vsync_wanted_cb` gets (`bridge`'s note).
    var vsync: TerminalVSync { bridgeObject.vsync }
    /// The hub the surface runs on (external vsync), nil: Ghostty's own display link per surface.
    private let vsyncSource: (any TerminalVSyncSource)?
    var cursor: NSCursor = .iBeam
    /// The terminal cursor on the render server (feature `terminalCursorLayer`, ``TerminalCursorLayer``); nil:
    /// Ghostty draws and blinks it (the feature off, or a GhosttyNextKit without `GHOSTTY_EXTERNAL_CURSOR`).
    let cursorLayer: TerminalCursorLayer?

    // Keyboard state (see TerminalSurfaceView+Keyboard.swift).
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    /// A UTF-16 lead surrogate an input method inserted alone (UnicodeHexInput); the next
    /// insertText brings its trail (upstream Ghostty #13737).
    var leadSurrogate: UTF16.CodeUnit?
    var lastPerformKeyEventTimestamp: TimeInterval?
    /// The key down `keyDown` runs through `interpretKeyEvents`, which `doCommand` re-sends.
    var interpretingKeyDown: NSEvent?
    /// Stamps the key's input method call in its latency slot (``TextInputStage``), from the window it joined.
    var textInputStage: TextInputStage?
    /// Where `doCommand` re-sends a chord no one claimed: the app's dispatch (a test records it).
    var resendKey: @MainActor (NSEvent) -> Void = { NSApp.sendEvent($0) }
    /// The input methods' turn for a key: nil is AppKit's (`interpretKeyEvents`, the selected input
    /// source); a test replays a recorded input method's calls (setMarkedText, insertText, doCommand).
    var inputMethod: (@MainActor (TerminalSurfaceView, NSEvent) -> Void)?
    var previousPressureStage = 0
    /// The left press went to Ghostty as a link click, in a program that has the mouse or with
    /// Shift- or Option-Command (``TerminalPointerMods``): its drags and release go the same way.
    var linkPressInCapture = false

    /// Keyboard copy mode (``TerminalCopyMode``).
    private(set) lazy var copyMode = TerminalCopyMode(view: self)
    /// Ghostty's clipboard reads and confirmations (``TerminalClipboardRequests``).
    private(set) lazy var clipboardRequests = TerminalClipboardRequests(view: self)
    /// Cmd-hover and Cmd-click on links beyond Ghostty's own (``TerminalLinkPointer``).
    private(set) lazy var linkPointer = TerminalLinkPointer(view: self, modifiers: modifierWatch)
    /// The terminals' one modifier watch (``TerminalModifierWatch``), from the session.
    let modifierWatch: TerminalModifierWatch?
    /// The windows' frame-aligned pointer input (feature `terminalPointerFrames`), from the session; nil:
    /// every pointer event reaches Ghostty at once.
    private let frameCoalescers: FrameInputCoalescers?
    /// Moves, drags and mouse-reporting trackpad scrolls on this view's window's coalescer
    /// (``TerminalPointerFrames``); nil while ``frameCoalescers`` is.
    private(set) lazy var pointerFrames: TerminalPointerFrames? = frameCoalescers.map { coalescers in
        TerminalPointerFrames(coalescers: coalescers) { [weak self] input in self?.deliverPointer(input) }
    }
    /// Whether the program has the mouse, read without the terminal's lock (``TerminalMouseCapture``).
    lazy var mouseCapture = TerminalMouseCapture(lane: lane)
    /// Where this view's pointer positions, buttons and scrolls go: its Ghostty surface, or a test's counter.
    // SAFETY: the sink holds this view's surface and goes with the view (GhosttyMouseSink).
    lazy var mouse: any TerminalMouseSink = unsafe GhosttyMouseSink(surface: surface)
    // SAFETY: the frame source holds this view's surface and goes with the view (GhosttyFrameSource).
    lazy var frameSource = unsafe GhosttyFrameSource(surface: surface, view: self)
    /// Where this view's backing scale and display go: its root layer and Ghostty surface.
    // SAFETY: the target holds this view's surface and goes with the view (GhosttyScaleTarget).
    lazy var scaleTarget: any TerminalScaleTarget = unsafe GhosttyScaleTarget(surface: surface, view: self)

    // MARK: Lifecycle

    /// - Parameter node: The terminal's tab node (`TerminalHostView.node`); nil: no tab (tests), the view's
    ///   node is a root.
    init(io mode: ghostty_surface_io_mode_e, input: TerminalInputSink, session: TerminalSession?,
         echoStages: TerminalEchoStages, hangWatch: (any HangWatchScoping)? = nil, secureInput: TerminalSecureInput,
         modifiers: TerminalModifierWatch? = nil, pointerFrames: FrameInputCoalescers? = nil,
         mainWork: MainWorkScheduler, node: VisibilityNode? = nil, gpuResidency: (any TerminalGPUResidency)? = nil,
         vsyncSource: (any TerminalVSyncSource)? = TerminalVSync.source(FrameScheduler.appDisplays.hub),
         externalCursor: Bool = false, lowersHiddenOutput: Bool = false) {
        let echoStage = echoStages.makeStage() // before the surface: the trace hook may see its first frame
        let cursorLayer = externalCursor && TerminalCursorLayer.isAvailable ? TerminalCursorLayer() : nil
        let bridge = SurfaceBridge(input: input, echoStage: echoStage, frameMarks: echoStages.frameMarks,
                                   keySlots: echoStages, cursor: cursorLayer?.presenter)
        // SAFETY: balanced by the one release in `deinit` (`bridge`'s note).
        self.bridge = unsafe Unmanaged.passRetained(bridge)
        self.session = session
        self.hangWatch = hangWatch
        self.lowersHiddenOutput = lowersHiddenOutput
        self.secureInput = secureInput
        modifierWatch = modifiers
        frameCoalescers = pointerFrames
        gpu = TerminalGPUResidencyGate(seam: gpuResidency)
        self.vsyncSource = vsyncSource
        self.cursorLayer = cursorLayer
        #if DEBUG || CMUX_BENCH_HOOKS
        showRecord = TerminalShowRecord(gate: echoStages.contentsGate)
        #endif
        offScreenRelease = TerminalOffScreenRelease(deadline: gpuResidency?.makeOffScreenDeadline())
        windowWatch = TerminalWindowWatch(node: node)
        let visibilityNode = node.map { VisibilityNode("terminal.surface", parent: $0) } ?? VisibilityNode(root: "terminal.surface", own: .visible)
        self.visibilityNode = visibilityNode
        windowNode = VisibilityNode("terminal.surface.window", own: .hidden, parent: visibilityNode)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        addCursorUpdateArea()
        bridge.target = self
        // Parking that changed under a hidden view told no one (``AppKit/NSView/notifyParkingChange()``): re-read it
        // when the view's node shows, before ``windowNode`` hears the flip.
        placementWatch = visibilityNode.subscribe(owner: "TerminalSurfaceView.placement") { [weak self] visibility in
            if visibility > .hidden { self?.syncPlacement() }
        }
        shownWatch = windowNode.subscribe(owner: "TerminalSurfaceView.shown") { [weak self] _ in self?.syncWindowState() }
        windowWatch.onChange = { [weak self] change in self?.windowStateChanged(change) }
        bridge.followLinkAnswers(on: mainWork)
        // Enter, exit and moves in any window state, one area for the surface's life (`.inVisibleRect`). The I-beam
        // has its own area (addCursorUpdateArea above): NSTrackingArea.h does not support `.activeAlways` with `.cursorUpdate`.
        // wakeup-allow: bounded mouse reporting and hover links follow the pointer over a terminal behind another app,
        // as in Ghostty; moves arrive only while the pointer is over this surface's visible rect
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                       owner: self))
        createSurface(mode: mode, echoStage: echoStage, stages: echoStages)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            windowWatch.stop()
            secureInput.release(ObjectIdentifier(self))
            if let surface {
                lane?.close()
                vsync.close() // no vsync tick reaches the surface after this
                // SAFETY: the one free of the view's surface (`surface`'s note), after the lane
                // that reaches it off the main thread closed.
                unsafe ghostty_surface_free(surface)
            }
            bridgeObject.surfaceFreed() // free joined every thread that reads the bridge: the hook stops reading it
            // Released after free: free joins the IO thread that reads the bridge.
            // SAFETY: the one release of `init`'s retain (`bridge`'s note), after the free.
            unsafe bridge.release()
        }
    }

    /// `ghostty_surface_new` with embedder-owned IO (ghostty.h:548-559, :627-629). `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` for
    /// the daemon, `GHOSTTY_SURFACE_IO_MANUAL` for a bare PTY. The bridge carries `echoStage` to ``GhosttyTraceHook``.
    private func createSurface(mode: ghostty_surface_io_mode_e, echoStage: TerminalEchoStage?, stages: TerminalEchoStages) {
        let timings = TerminalTimings()
        let signpost = timings.surfaceCreateBegan()
        defer { timings.surfaceCreated(signpost) }
        guard let app = GhosttyRuntime.shared.app else { return }
        // SAFETY: the bridge outlives the surface (`bridge`'s note), and the view, whose address
        // Ghostty keeps as its NSView, frees the surface in its own deinit. Ghostty copies the
        // config during ghostty_surface_new; the callback has the signature ghostty.h declares.
        let userdata = unsafe bridge.toOpaque()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        // SAFETY: as above; the NSView is this view's address (its identity's bits), not a callback context.
        unsafe config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: ObjectIdentifier(self)))))
        // SAFETY: as above.
        unsafe config.userdata = userdata
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.io_mode = mode
        // SAFETY: as above.
        unsafe SurfaceBridge.setCallbacks(in: &config, userdata: userdata)
        // SAFETY: as above; the pacer is the bridge's (`vsync`).
        if vsyncSource != nil { unsafe SurfaceBridge.setExternalVSync(in: &config, userdata: userdata) }
        #if GHOSTTY_EXTERNAL_CURSOR
        if cursorLayer != nil {
            // Ghostty neither draws nor blinks the cursor; it presents each cursor cell with its frame on the cursor layer.
            config.cursor_external = true
            // SAFETY: the callback has ghostty_surface_cursor_cb's signature; `userdata` as above.
            unsafe config.cursor_cb = ghosttySurfaceCursor
            // SAFETY: as above.
            unsafe config.cursor_userdata = userdata
        }
        #endif
        // The runtime's first surface pays the font discovery and the Metal device's first use: its phases are split.
        var split = GhosttyRuntime.shared.firstSurfaceSplit.begin()
        // SAFETY: as above; `app` is the runtime's live app (never freed).
        guard let surface = unsafe ghostty_surface_new(app, &config) else {
            split?.ended(.surfaceNew)
            GhosttyRuntime.logger.error("ghostty_surface_new failed")
            return
        }
        split?.ended(.surfaceNew)
        // SAFETY: the new surface, owned by this view and freed once, in deinit (`surface`'s note).
        self.surface = unsafe surface
        // SAFETY: as above; deinit closes the pacer before the free.
        if vsyncSource != nil { unsafe vsync.attach(surface: surface) }
        // SAFETY: the view's live surface (`surface`); the hook reads only its trace id.
        unsafe bridgeObject.traceFrames(of: surface, with: stages.traceHook)
        // The drawable follows the size this view sets (`setFrameSize`), not
        // its layer's bounds: one synchronous frame per size change at the
        // next display pass, no draw for a bounds change alone.
        // SAFETY: the view's live surface (`surface`).
        unsafe ghostty_surface_set_host_sized(surface, true)
        TerminalFontScale(self).installCallback()
        GhosttyLockWaitSignpost.install(on: surface, bridge: bridge)
        // Light/dark themes (default Apple System Colors) follow the app.
        GhosttyRuntime.shared.registerColorScheme(of: self)
        // SAFETY: the lane owns the off-main uses of the surface until `deinit` closes it, before
        // the free (TerminalOutputLane).
        lane = unsafe TerminalOutputLane(surface: surface, label: "com.cmuxterm.next.terminal.output", echoStage: echoStage,
                                         keyFlows: bridgeObject.typingSurface, hangs: hangWatch,
                                         lowersHidden: lowersHiddenOutput)
        lane?.setHidden(isRenderingSuspended)
        if let layer {
            cursorLayer?.install(on: layer)
            echoStage?.attach(to: layer)
            #if DEBUG || CMUX_BENCH_HOOKS
            showRecord.attach(to: layer)
            #endif
            TypingFrameProbe.install(on: layer, stages: stages, keyFlows: bridgeObject.typingSurface)
        }
        registerForDraggedTypes([.fileURL, .URL, .string])
        split?.ended(.surfaceSetup)
        updateContentScale()
        updateSurfaceSize()
        split?.ended(.surfaceFit)
        updateOcclusion()
        updateFocus()
        split?.ended(.surfaceState)
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
        // Pending pointer input is in the old window's coordinates: it never reaches the surface.
        if newWindow !== window { pointerFrames?.cancel() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        textInputStage = (window as? TextInputStageHosting)?.textInputStage
        cursorLayer?.place(in: window)
        let before = windowNode.effective
        ancestorsMoved() // a window it joins may hold it under a hidden container: no viewDidHide comes then
        syncPlacement()
        // A move between windows flips nothing: observe the new window (the old one's observers went above), and
        // take its scale and the view's size in it.
        if windowNode.effective == before {
            syncWindowState()
            if isShown { reconcileShown() }
        }
    }

    /// The view's own overlays (copy mode's box and badge, predictive echo) stay over the cursor layer, as they
    /// were over the cursor Ghostty drew.
    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if cursorLayer != nil { subview.layer?.zPosition = TerminalCursorLayer.subviewZPosition }
    }

    /// Ghostty presented cursor cells (``ghosttySurfaceCursor(_:_:)``): the blink follows the newest.
    func cursorCellsDidChange() {
        cursorLayer?.cellsDidChange()
    }

    /// The terminal in the visibility tree (recipe R-hide, TerminalSurfaceView+Visibility.swift): under its
    /// tab's node, own-hidden while AppKit hides the view or an ancestor.
    let visibilityNode: VisibilityNode
    /// The terminal in its window: under ``visibilityNode``, own-hidden while the view is in no window or a
    /// container above is parked (``syncPlacement()``). Its effective state is the terminal's: its edge to
    /// shown reconciles the surface's scale and size (``reconcileShown()``).
    let windowNode: VisibilityNode
    /// Runs ``syncWindowState()`` on each flip of ``windowNode``.
    private var shownWatch: VisibilitySubscription?
    /// Whether ``syncWindowState()`` last saw the terminal shown: its edge to shown runs ``reconcileShown()`` once.
    var reconciledShown = false
    /// Runs ``syncPlacement()`` when ``visibilityNode`` shows.
    private var placementWatch: VisibilitySubscription?
    /// In a window, its nodes not hidden and no container above parked (``windowNode``). A layout change of
    /// a terminal that is not shown records its size only (PL-script A3: a hidden workspace's layout sized
    /// every warm terminal's surface and resized its PTY); showing it applies the last size once.
    var isShown: Bool { windowNode.effective > .hidden }


    func observeWindow(_ observe: Bool) {
        guard observe != windowWatch.isWatching else { return }
        windowWatch.stop()
        windowNodeWatch = nil
        guard observe, let window else { return }
        windowNodeWatch = watchWindowNode(of: window)
        windowWatch.followKey(window.firstResponder === self)
        windowWatch.watch(WindowEvents.of(window))
    }

    /// Window notices handled (`debug.layout_counters`): only shown terminals count, key changes only for the
    /// first responder, screen changes only while their tab is visible.
    public static var windowStateUpdates: UInt64 = 0
    /// Grid reports views made to their session (`debug.window_transition`).
    public static var gridReports: UInt64 = 0

    /// Applies the window's current state for `change`: each step is a no-op when nothing changed, so a missed
    /// notice read on show costs nothing.
    private func windowStateChanged(_ change: TerminalWindowWatch.Change) {
        Self.windowStateUpdates &+= 1
        switch change {
        case .screen:
            updateContentScale()
            updateSurfaceSize()
        case .focus:
            updateFocus()
        }
    }

    /// AppKit walks hidden and parked views too; a terminal that is not shown takes its scale from its
    /// window when it shows (``reconcileShown()``). Each scale or display call is a message that wakes the
    /// surface's renderer thread, which stays parked while the surface is paused and GPU-released.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard isShown else { return }
        updateContentScale()
        updateSurfaceSize()
    }

    /// Every frame of a drag resizes a shown surface at once (a hidden one sizes from its bounds when it
    /// shows, ``reconcileShown()``): the drawable takes
    /// the new size and draws one frame with the text reflowed to it (the
    /// reflow preview, ``updateReflowPreview()``), and the grid report goes to
    /// the owner through `ResizeCoordinator` (next frame, one in flight). The
    /// owner's announcement then shows the same rows.
    public override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { updateSurfaceSize() }
        cursorLayer?.layout(size: newSize)
        copyMode.syncCursor()
    }

    /// The window's backing scale and screen to the root layer and surface (``TerminalContentScale``).
    func updateContentScale() {
        guard surface != nil else { return }
        let screen = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let backing = TerminalBacking(windowScale: window?.backingScaleFactor,
                                      contentScale: convertToBacking(NSSize(width: 1, height: 1)),
                                      displayID: screen?.uint32Value)
        let shownOn = appliedDisplayID
        appliedBacking.apply(backing, to: scaleTarget)
        if appliedDisplayID != shownOn { followVSync() } // ticks come from the new display's clock
    }

    /// Subscribes the surface to its display's vsync while it draws, and leaves while it does not
    /// (``TerminalVSync/follow(_:source:)``); a surface on Ghostty's own display link does nothing.
    private func followVSync() {
        guard surface != nil, let vsyncSource else { return }
        vsync.follow(pause == nil ? appliedDisplayID ?? CGMainDisplayID() : nil, source: vsyncSource)
    }

    /// The owner announced `grid`: the surface renders it and reports against it. Its lock
    /// (`ghostty_surface_set_grid`) is already queued on the output lane at the owner's point in the
    /// byte stream (``TerminalOutputLane/lockGrid(_:)``); this is the view's side, once per frame.
    func applyAnnouncedGrid(_ grid: TerminalGridSize) {
        geometry.announce(grid)
        updateSurfaceSize()
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
        // SAFETY: the view's live surface (`surface`).
        unsafe ghostty_surface_set_reflow_preview(surface, enabled)
    }

    /// Sizes the surface to the view and reports the view's grid when the
    /// owner does not have it.
    ///
    /// The view's pixel size always goes to `ghostty_surface_set_size`, and
    /// `ghostty_surface_size` reports how many cells fit. Before any
    /// announcement that is also the terminal grid. After one, the terminal
    /// grid is locked to the announced grid (`ghostty_surface_set_grid`):
    /// a larger view draws padding, a smaller one crops, and the report still
    /// says what would fit. The owner decides; the surface follows its
    /// announcement.
    ///
    /// A terminal that is not shown (made, hidden, parked) does nothing: its size is its bounds, read
    /// again when it shows (``reconcileShown()``), never a request kept for later
    /// (plans principled-audit R2: PL-script A3's hidden resizes cost nothing, and no missed show can
    /// leave a stale grid).
    func updateSurfaceSize() {
        guard let surface, isShown else { return }
        let pixels = convertToBacking(bounds.size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        defer { copyMode.syncCursor() }
        TerminalHostFramePresenter.setSize(of: self, to: pixels)  // its drawn frame into this turn's commit
        // SAFETY: the view's live surface (`surface`).
        let size = unsafe ghostty_surface_size(surface)
        publish(size: size)
        guard size.columns > 0, size.rows > 0 else { return }
        let desired = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        // A pane on a layout spring (Cmd-Shift-Enter zoom, split, close) resizes this view on every
        // display frame: the surface draws each size (the reflow preview), and the grid goes to the
        // owner once the spring lands (`paneMotionDidSettle`), one PTY resize instead of one per frame.
        let report = geometry.viewSized(desired, holding: isInPaneMotion)
        // In the same main-thread turn as set_size: the frame of the new size
        // draws at the next display pass, already reflowed.
        // A held grid is reported when the spring lands: the preview draws it meanwhile.
        updateReflowPreview(reporting: report != nil || geometry.held)
        guard let report else { return }
        Self.gridReports &+= 1
        let cells = metrics.cellPixels(of: report)
        session?.surfaceDidReport(grid: report, pixelWidth: cells.width, pixelHeight: cells.height)
    }

    /// The PTY owner has no grid from this view (a new session or owner, or it took over geometry): it
    /// gets the view's grid now when shown, else when the view shows (``TerminalGridPolicy/ownerNeedsReport()``).
    func reportToNewOwner() {
        geometry.ownerNeedsReport()
        updateSurfaceSize()
    }

    /// The one reconcile of a terminal that becomes shown (its ``windowNode`` turned shown): scale and size
    /// from its window and bounds now, whatever changed while it was not shown. A view that joins a pane on
    /// a layout spring sends the grid the spring rests at first (``joinPaneMotion()``).
    func reconcileShown() {
        updateContentScale()
        if isInPaneMotion { _ = joinPaneMotion() }
        updateSurfaceSize()
    }

    private func publish(size: ghostty_surface_size_s) {
        guard let model = session?.model else { return }
        let grid = geometry.gridToRender ?? TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        if model.grid != grid { model.grid = grid }
        let cell = CGSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px))
        if model.cellPixelSize != cell { model.cellPixelSize = cell }
    }

    /// The grid the surface renders now: the locked grid, or what fits the
    /// view before a lock.
    var currentGrid: TerminalGridSize? {
        guard let surface else { return nil }
        // SAFETY: the view's live surface (`surface`).
        let grid = unsafe ghostty_surface_grid(surface)
        if grid.locked { return TerminalGridSize(columns: Int(grid.columns), rows: Int(grid.rows)) }
        // SAFETY: the view's live surface (`surface`).
        let size = unsafe ghostty_surface_size(surface)
        return TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
    }

    /// Cell size in points, for IME rectangles.
    var cellPointSize: CGSize {
        guard let surface else { return CGSize(width: 8, height: 16) }
        // SAFETY: the view's live surface (`surface`).
        let size = unsafe ghostty_surface_size(surface)
        let backing = convertFromBacking(NSSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px)))
        return CGSize(width: max(backing.width, 1), height: max(backing.height, 1))
    }

    // MARK: Focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            windowWatch.followKey(true)
            updateFocus(firstResponder: true)
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            windowWatch.followKey(false)
            updateFocus(firstResponder: false)
        }
        return accepted
    }

    var isFirstResponder: Bool { window?.firstResponder === self }

    /// Focus is first responder in the key window. Ghostty uses it for cursor
    /// style and for focus reports (mode 1004) to the program.
    func updateFocus(firstResponder: Bool? = nil) {
        guard let surface else { return }
        let focused = (firstResponder ?? isFirstResponder) && (window?.isKeyWindow ?? false)
        guard focused != lastFocus else { return }
        lastFocus = focused
        // SAFETY: the view's live surface (`surface`).
        unsafe ghostty_surface_set_focus(surface, focused)
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
            // SAFETY: the view's live surface (`surface`); Swift passes a NUL-terminated copy of
            // `action` for the call, its length without the NUL.
            unsafe ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        // SAFETY: the view's live surface (`surface`).
        return unsafe ghostty_surface_has_selection(surface)
    }
}

/// A workspace parked without hiding pauses this surface and drops its window observers, as hiding
/// does; shown again it catches up (`syncWindowState`).
extension TerminalSurfaceView: ParkingObserver {
    public func parkingDidChange() { syncPlacement() }
}
