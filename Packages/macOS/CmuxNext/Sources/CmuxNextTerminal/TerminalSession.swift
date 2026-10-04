public import AppKit
public import CmuxNextTerminalFind
import CmuxNextWakeups
import GhosttyNextKit

/// One terminal on screen: a Ghostty surface fed by a ``TerminalIO``.
///
/// Embed ``view``. The session consumes `io.events` on the main actor,
/// feeds bytes through a serial off-main output lane, and writes Ghostty's
/// encoded input back to `io.write` in order. Consumption is demand-driven:
/// the next event is taken only once the lane has room, so a slow parser
/// pushes back on the IO (which bounds its own buffer) instead of queueing
/// without limit (state-audit.md T1).
///
/// Geometry: the mirror's grid must equal the PTY's grid at every point in
/// the byte stream, or later output lands in the wrong cells. The IO owner
/// decides the PTY size; every `.resize` event locks the live surface's grid
/// in place (`ghostty_surface_set_grid`, queued on the output lane behind
/// every earlier chunk), and never replaces the surface. Once one arrived the surface
/// renders only `.resize` grids (``TerminalGridPolicy``). When
/// ``ownsGeometry`` is true the grid the view fits is sent with `io.resize`,
/// once per change, as a request: the surface follows when the owner
/// announces the grid it applied. A request the owner does not apply
/// (another client holds geometry) never shows as a grid the PTY does not
/// have. An IO that never sends `.resize` (a bare PTY, resized by the
/// request itself) keeps the surface sized to the view.
@MainActor
public final class TerminalSession {
    public let model = TerminalSurfaceModel()
    public let view: TerminalHostView
    /// The find bar over this terminal and the search it drives.
    public let find = TerminalFindController()
    public weak var delegate: (any TerminalSessionDelegate)?

    /// The live surface. Replaced when a later VT replay arrives; a GHOSTSNP
    /// snapshot restores in place.
    public private(set) var surfaceView: TerminalSurfaceView

    public var ownsGeometry: Bool {
        didSet { surfaceView.ownsGeometry = ownsGeometry }
    }

    /// Pauses rendering while the terminal is scrolled off-screen (strip
    /// columns) or its tab is not selected. Output keeps being parsed.
    public var isRenderingSuspended = false {
        didSet { surfaceView.isRenderingSuspended = isRenderingSuspended }
    }

    /// This terminal's theme when it differs from the Ghostty config (its
    /// own, its workspace's or its room's); nil uses the config. Applied to
    /// the live surface in place (`ghostty_surface_update_config`: palette,
    /// background, foreground, cursor, selection), with no restart and no
    /// grid change, and to every surface a later replay swaps in.
    public private(set) var theme: GhosttyThemeConfig?
    /// The light/dark scheme the live surface draws a light/dark theme in.
    public var surfaceIsDark: Bool { surfaceView.colorSchemeIsDark }

    /// Sets ``theme``. `force` re-applies an unchanged one, after a config
    /// reload pushed the app config to every surface.
    public func setTheme(_ config: GhosttyThemeConfig?, force: Bool = false) {
        let previous = theme
        guard force || config !== previous else { return }
        theme = config
        view.theme = config
        applyTheme(to: surfaceView, clearing: previous != nil && config == nil)
    }

    /// Mirrors currently shown. Forwarded to whichever surface is live so a
    /// hover preview stays live across a surface swap.
    var mirrorDemand = 0 {
        didSet { surfaceView.mirrorDemand = mirrorDemand }
    }

    private let io: any TerminalIO
    private let ioMode: ghostty_surface_io_mode_e
    private let input: TerminalInputSink
    private var eventsTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    /// Latest `.resize` grid, re-applied to a swapped-in surface.
    private var canonicalGrid: TerminalGridSize?
    /// True once the current surface received a replay or output; a later
    /// replay then needs a fresh surface.
    private(set) var surfaceHasContent = false
    /// READY snapshots restored in place, and surfaces swapped in for a
    /// later VT replay (diagnostics: a snapshot attach never swaps).
    private(set) var restoredSnapshots = 0
    private(set) var swappedSurfaces = 0

    public init(io: any TerminalIO, ownsGeometry: Bool = true) {
        self.io = io
        self.ownsGeometry = ownsGeometry
        ioMode = io.answersTerminalQueries ? GHOSTTY_SURFACE_IO_MANUAL_MIRROR : GHOSTTY_SURFACE_IO_MANUAL

        // concurrency-allow: carries only user input and resizes, produced at human rate
        let (outgoing, continuation) = AsyncStream<TerminalOutgoing>.makeStream(bufferingPolicy: .unbounded)
        input = TerminalInputSink(continuation: continuation)

        view = TerminalHostView()
        surfaceView = TerminalSurfaceView(io: ioMode, input: input, session: nil)
        surfaceView.session = self
        surfaceView.ownsGeometry = ownsGeometry
        view.install(surfaceView)
        find.target = self
        view.attachFind(find)

        writerTask = Task.detached(priority: .userInitiated) { [io] in
            for await item in outgoing {
                switch item {
                case .bytes(let data):
                    await io.write(data)
                case .resize(let grid, let width, let height):
                    await io.resize(cols: grid.columns, rows: grid.rows, pixelWidth: width, pixelHeight: height)
                case .focusGained:
                    await io.focusGained()
                case .reconnect:
                    await io.reconnectRequested()
                }
            }
        }

        let events = io.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        // The first grid report fired inside the surface init, before
        // `session` was set; report it now.
        surfaceView.updateSurfaceSize(forceReport: true)
    }

    isolated deinit {
        eventsTask?.cancel()
        writerTask?.cancel()
        input.finish()
    }

    // MARK: Public API

    /// Makes the surface first responder.
    public func focus() {
        surfaceView.window?.makeFirstResponder(surfaceView)
    }

    /// Sends text as if pasted (Ghostty applies bracketed paste when the
    /// program enabled it). The encoded bytes reach `io.write`.
    public func sendText(_ text: String) {
        guard let surface = surfaceView.surface, !text.isEmpty else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    /// Downscaled image of the last presented frame, for static previews.
    public func snapshot(maxPixelSize: CGFloat = 480) -> CGImage? {
        surfaceView.snapshot(maxPixelSize: maxPixelSize)
    }

    /// ``snapshot(maxPixelSize:)`` rendered off the main thread (it waits on the GPU).
    public func snapshotInBackground(maxPixelSize: CGFloat = 480) async -> CGImage? {
        await surfaceView.snapshotInBackground(maxPixelSize: maxPixelSize)
    }

    /// A live, zero-copy scaled mirror for hover previews. See
    /// ``TerminalMirrorView``.
    public func makeMirrorView() -> TerminalMirrorView {
        TerminalMirrorView(session: self)
    }

    /// Stops consuming events and detaches the surface. The IO owner decides
    /// whether the underlying terminal keeps running.
    public func close() {
        eventsTask?.cancel()
        eventsTask = nil
        input.finish()
        surfaceView.removeFromSuperview()
    }

    // MARK: Events

    private func handle(_ event: TerminalIOEvent) async {
        switch event {
        case .replay(let data):
            if surfaceHasContent { swapSurface() }
            surfaceView.lane?.processOutput(data)
            surfaceHasContent = true
            TerminalTimings.contentApplied()
        case .kittyReplay(let replay):
            // GhosttyNextKit restores Kitty graphics through GHOSTSNP snapshots
            // (terminal-snapshot-v1), not the desktop fork's kitty replay. Until
            // this view attaches in snapshot mode (S2b), the VT part is
            // replayed and on-screen Kitty images come back only when the
            // program draws them again.
            if surfaceHasContent { swapSurface() }
            surfaceView.lane?.processOutput(replay.vt)
            surfaceHasContent = true
            TerminalTimings.contentApplied()
        case .snapshot(let data, let phase):
            // The same surface takes the owner's state: no swap.
            let restored = await restoreSnapshot(data, phase: phase)
            guard phase == .ready, restored else { return }
            restoredSnapshots += 1
            surfaceHasContent = true
            TerminalTimings.contentApplied()
        case .output(let data):
            ExpectedActivity.shared.note(.terminalOutput)
            guard let lane = surfaceView.lane else { return }
            await lane.waitForCapacity()
            // The surface may have been swapped while waiting (a replay).
            surfaceView.lane?.processOutput(data)
            surfaceHasContent = true
            TerminalTimings.contentApplied()
        case .resize(let columns, let rows):
            guard columns > 0, rows > 0 else { return }
            await applyCanonicalGrid(TerminalGridSize(columns: columns, rows: rows))
        case .exited:
            model.hasExited = true
        case .status(let status):
            model.connection = status
            model.hasExited = status == .exited
            view.showStatus(status)
        }
    }

    /// A click in the surface: a disconnected terminal re-attaches.
    func surfaceClicked() {
        guard case .disconnected(_, reconnecting: false) = model.connection else { return }
        input.reconnect()
    }

    /// Locks the live mirror to the owner's grid in stream order: the lock
    /// is queued on the output lane behind every chunk received before this
    /// event, so Ghostty reflows the same screen the owner reflowed. Every
    /// `.resize` applies; the event is the PTY's size at this point in the
    /// stream.
    private func applyCanonicalGrid(_ grid: TerminalGridSize) async {
        canonicalGrid = grid
        surfaceView.applyAnnouncedGrid(grid)
    }

    /// Ghostty has no reset API, so a new replay goes into a new surface
    /// that takes the old one's place (cmux-tui-contract.md 3.2).
    private func swapSurface() {
        let old = surfaceView
        let wasFirstResponder = old.isFirstResponder
        let fresh = TerminalSurfaceView(io: ioMode, input: input, session: self)
        swappedSurfaces += 1
        fresh.ownsGeometry = ownsGeometry
        fresh.isRenderingSuspended = isRenderingSuspended
        fresh.mirrorDemand = mirrorDemand
        surfaceView = fresh
        view.install(fresh)
        applyTheme(to: fresh, clearing: false)
        // Nothing was parsed into the fresh surface yet: no drain needed.
        if let canonicalGrid { fresh.applyAnnouncedGrid(canonicalGrid) }
        if wasFirstResponder { fresh.window?.makeFirstResponder(fresh) }
        surfaceHasContent = false
        // The fresh surface has no search; an open find bar searches it again.
        find.surfaceReplaced()
    }

    /// A new surface starts from the app config, so only a theme needs
    /// applying; clearing one re-applies the app config (Ghostty resolves
    /// its light/dark variant per surface).
    private func applyTheme(to surfaceView: TerminalSurfaceView, clearing: Bool) {
        guard let surface = surfaceView.surface else { return }
        if let theme {
            ghostty_surface_update_config(surface, theme.config)
        } else if clearing, let config = GhosttyRuntime.shared.config {
            ghostty_surface_update_config(surface, config)
        }
    }

    // MARK: From the surface view

    func surfaceDidGainFocus() {
        input.focusGained()
    }

    func surfaceDidReport(grid: TerminalGridSize, pixelWidth: Int, pixelHeight: Int) {
        guard ownsGeometry else { return }
        input.resize(grid, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
