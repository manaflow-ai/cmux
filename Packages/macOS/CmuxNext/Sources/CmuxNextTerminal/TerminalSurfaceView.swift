public import AppKit
import CmuxNextDesign
import CmuxNextTerminalGeometry
import CmuxNextWakeups
import GhosttyNextKit
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

    /// Grid the PTY owner announced last (``applyAnnouncedGrid(_:)``).
    var announcedGrid: TerminalGridSize? { geometry.announced }

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
    private var lastFocus: Bool?
    private var windowObservers: [any NSObjectProtocol] = []
    var trackingArea: NSTrackingArea?
    var cursor: NSCursor = .iBeam

    // Keyboard state (see TerminalSurfaceView+Keyboard.swift).
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var lastPerformKeyEventTimestamp: TimeInterval?
    var previousPressureStage = 0

    /// Keyboard copy mode (``TerminalCopyMode``).
    private(set) lazy var copyMode = TerminalCopyMode(view: self)
    /// Ghostty's clipboard reads and confirmations (``TerminalClipboardRequests``).
    private(set) lazy var clipboardRequests = TerminalClipboardRequests(view: self)

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

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        TerminalSecureInput.release(self)
        if let surface {
            lane?.close()
            ghostty_surface_free(surface)
        }
        // Released after free: free joins the IO thread that reads the bridge.
        bridge.release()
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
        TerminalFontScale(self).installCallback()
        // Light/dark themes (default Apple System Colors) follow the app.
        GhosttyRuntime.shared.registerColorScheme(of: self)
        lane = TerminalOutputLane(surface: surface, label: "com.cmuxterm.next.terminal.output")
        if TypingLatencyProbe.isEnabled, let layer { TypingFrameProbe.install(on: layer) }
        registerForDraggedTypes([.fileURL, .URL, .string])
        updateContentScale()
        updateSurfaceSize(forceReport: true)
        updateOcclusion()
        updateFocus()
    }

    public override var isFlipped: Bool { false }

    // MARK: Window, scale, and size

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        guard let newWindow else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for name in names {
            windowObservers.append(center.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.windowStateChanged(name) }
            })
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentScale()
        updateSurfaceSize()
        updateOcclusion()
        updateFocus()
    }

    private func windowStateChanged(_ name: Notification.Name) {
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

    public override func viewDidHide() {
        super.viewDidHide()
        updateOcclusion()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateOcclusion()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        updateSurfaceSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
        copyMode.syncCursor()
    }

    /// `ghostty_surface_set_content_scale` + `ghostty_surface_set_display_id`
    /// (ghostty.h:1440, :1821).
    private func updateContentScale() {
        guard let surface else { return }
        let scale = convertToBacking(NSSize(width: 1, height: 1))
        ghostty_surface_set_content_scale(surface, scale.width, scale.height)
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
            if let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
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
        let pixels = convertToBacking(bounds.size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
        let size = ghostty_surface_size(surface)
        publish(size: size)
        guard size.columns > 0, size.rows > 0 else { return }
        let desired = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        let metrics = TerminalGridMetrics(cellWidth: Int(size.cell_width_px), cellHeight: Int(size.cell_height_px),
                                          paddingWidth: 0, paddingHeight: 0)
        guard let report = geometry.viewSized(desired, force: forceReport) else { return }
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
        guard (pause == nil) != lastOcclusionVisible else { return }
        lastOcclusionVisible = pause == nil
        ghostty_surface_set_occlusion(surface, pause == nil)
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
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }
}
