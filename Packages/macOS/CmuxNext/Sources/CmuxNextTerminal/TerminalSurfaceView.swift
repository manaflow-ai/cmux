public import AppKit
import GhosttyKit
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
    private let bridge: Unmanaged<SurfaceBridge>
    /// Serial lane for output and other process_output-ordered calls.
    private(set) var lane: TerminalOutputLane?
    weak var session: TerminalSession?

    /// Whether this view's pixel size decides the terminal grid. Followers
    /// render the daemon's canonical grid instead (shell.md 2.3).
    var ownsGeometry = true {
        didSet { if ownsGeometry != oldValue { updateSurfaceSize(forceReport: true) } }
    }

    /// Grid decided by the daemon (``applyCanonicalGrid(_:)``).
    private(set) var canonicalGrid: TerminalGridSize?
    /// Grid the view's own pixel size produced at the last sizing.
    private(set) var viewGrid: TerminalGridSize?
    /// Backing pixel size of the last owner sizing.
    private var viewPixels: CGSize?
    /// An owner is rendering ``canonicalGrid`` instead of its view grid
    /// because another client sized the terminal differently.
    private var showsCanonicalGrid = false

    /// App-controlled pause (off-screen niri column, unselected tab).
    var isRenderingSuspended = false {
        didSet { if isRenderingSuspended != oldValue { updateOcclusion() } }
    }

    /// Mirrors attached to this view. While positive the surface keeps
    /// rendering even when hidden, so hover previews stay live.
    var mirrorDemand = 0 {
        didSet { if (mirrorDemand > 0) != (oldValue > 0) { updateOcclusion() } }
    }

    /// Last grid reported to the owner, so a resize that keeps the same
    /// cell count does not generate a daemon `resize-surface`.
    private var reportedGrid: TerminalGridSize?
    private var lastOcclusionVisible: Bool?
    private var lastFocus: Bool?
    private var windowObservers: [any NSObjectProtocol] = []
    var trackingArea: NSTrackingArea?
    var cursor: NSCursor = .iBeam

    // Keyboard state (see TerminalSurfaceView+Keyboard.swift).
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var lastPerformKeyEventTimestamp: TimeInterval?
    var previousPressureStage = 0

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
        lane = TerminalOutputLane(surface: surface, label: "com.cmuxterm.next.terminal.output")
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

    /// Makes the mirror's grid match the daemon's. Call only when every
    /// earlier output chunk has been parsed (``TerminalSession`` drains the
    /// lane first), so the reflow happens at the same point in the byte
    /// stream as the daemon's.
    ///
    /// A follower always renders the canonical grid. An owner keeps its view
    /// grid when they match (the usual echo of its own report) and otherwise
    /// renders the canonical grid until its view size changes again.
    func applyCanonicalGrid(_ grid: TerminalGridSize) {
        canonicalGrid = grid
        guard surface != nil else { return }
        if !ownsGeometry {
            renderCanonicalGrid()
        } else if grid == viewGrid {
            guard showsCanonicalGrid else { return }
            showsCanonicalGrid = false
            updateSurfaceSize(forceReport: false, viewChanged: true)
        } else {
            showsCanonicalGrid = true
            renderCanonicalGrid()
        }
    }

    /// `ghostty_surface_set_grid_size` (ghostty.h:1464): resizes the live
    /// terminal in place; Ghostty reflows it exactly like the daemon's core.
    private func renderCanonicalGrid() {
        guard let surface, let canonicalGrid,
              let columns = UInt16(exactly: canonicalGrid.columns), let rows = UInt16(exactly: canonicalGrid.rows)
        else { return }
        var resolved = ghostty_surface_size_s()
        if ghostty_surface_set_grid_size(surface, columns, rows, &resolved) {
            publish(size: resolved)
        }
    }

    /// Owner: size the surface to the view and report a changed grid.
    /// Follower: render the canonical grid regardless of the view size.
    /// An owner showing a canonical grid keeps it until the view's pixel
    /// size actually changes (a layout pass at the same size is not a
    /// resize).
    func updateSurfaceSize(forceReport: Bool = false, viewChanged: Bool = false) {
        guard let surface else { return }
        if !ownsGeometry {
            if canonicalGrid != nil { renderCanonicalGrid() }
            return
        }
        let pixels = convertToBacking(bounds.size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        if showsCanonicalGrid, !viewChanged, !forceReport, pixels == viewPixels {
            // Same view size; cell metrics may have changed (font size).
            renderCanonicalGrid()
            return
        }
        showsCanonicalGrid = false
        viewPixels = pixels
        ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
        let size = ghostty_surface_size(surface)
        publish(size: size)
        guard size.columns > 0, size.rows > 0 else { return }
        let grid = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        viewGrid = grid
        if forceReport || grid != reportedGrid {
            reportedGrid = grid
            session?.surfaceDidReport(grid: grid, pixelWidth: Int(size.width_px), pixelHeight: Int(size.height_px))
        }
    }

    private func publish(size: ghostty_surface_size_s) {
        guard let model = session?.model else { return }
        let grid = TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
        if model.grid != grid { model.grid = grid }
        let cell = CGSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px))
        if model.cellPixelSize != cell { model.cellPixelSize = cell }
    }

    /// The grid the surface renders now.
    var currentGrid: TerminalGridSize? {
        guard let surface else { return nil }
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

    /// `ghostty_surface_set_occlusion(surface, visible)` (ghostty.h:1442).
    /// Hidden surfaces stop drawing but keep parsing output.
    func updateOcclusion() {
        guard let surface else { return }
        let onScreen = window.map { $0.occlusionState.contains(.visible) } ?? false
        let visible = mirrorDemand > 0 || (onScreen && !isHiddenOrHasHiddenAncestor && !isRenderingSuspended)
        guard visible != lastOcclusionVisible else { return }
        lastOcclusionVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
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
