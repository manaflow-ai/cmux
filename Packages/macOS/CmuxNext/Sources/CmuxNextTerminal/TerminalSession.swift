public import AppKit
import GhosttyKit

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
/// the byte stream, or later output lands in the wrong cells. A `.resize`
/// event resizes the live surface in place (`ghostty_surface_set_grid_size`)
/// after every earlier chunk was parsed; it never replaces the surface. When
/// ``ownsGeometry`` is true the view size decides the grid, changes are sent
/// with `io.resize`, and a `.resize` that matches the view is a no-op; one
/// that differs (another client sized the terminal) is rendered until the
/// view size changes. When false the surface always renders the `.resize`
/// grid, which is how a second view of the same daemon terminal stays
/// consistent (native-frontend.md: "selecting a visible terminal view
/// explicitly transfers canonical geometry").
public final class TerminalSession {
    public let model = TerminalSurfaceModel()
    public let view: TerminalHostView
    public weak var delegate: (any TerminalSessionDelegate)?

    /// The live surface. Replaced when a later replay arrives.
    public private(set) var surfaceView: TerminalSurfaceView

    public var ownsGeometry: Bool {
        didSet { surfaceView.ownsGeometry = ownsGeometry }
    }

    /// Pauses rendering while the terminal is scrolled off-screen (niri
    /// columns) or its tab is not selected. Output keeps being parsed.
    public var isRenderingSuspended = false {
        didSet { surfaceView.isRenderingSuspended = isRenderingSuspended }
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
    private var canonicalGrid: TerminalGridSize?
    /// Grids this view reported most recently, oldest first. A `.resize`
    /// carrying an older one is the daemon's late echo of a size the view
    /// already left, not another client's geometry.
    private var recentReports: [TerminalGridSize] = []
    /// True once the current surface received a replay or output; a later
    /// replay then needs a fresh surface.
    private(set) var surfaceHasContent = false

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

        writerTask = Task.detached(priority: .userInitiated) { [io] in
            for await item in outgoing {
                switch item {
                case .bytes(let data):
                    await io.write(data)
                case .resize(let grid, let width, let height):
                    await io.resize(cols: grid.columns, rows: grid.rows, pixelWidth: width, pixelHeight: height)
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
        case .kittyReplay(let replay):
            if surfaceHasContent { swapSurface() }
            restoreKittyReplay(replay)
            surfaceHasContent = true
        case .output(let data):
            guard let lane = surfaceView.lane else { return }
            await lane.waitForCapacity()
            // The surface may have been swapped while waiting (kitty restore fallback).
            surfaceView.lane?.processOutput(data)
            surfaceHasContent = true
        case .resize(let columns, let rows):
            guard columns > 0, rows > 0 else { return }
            await applyCanonicalGrid(TerminalGridSize(columns: columns, rows: rows))
        case .exited:
            model.hasExited = true
        }
    }

    /// `ghostty_surface_restore_kitty_replay` (ghostty.h:1614-1628) runs on
    /// the output lane so it is ordered before any later output. On failure
    /// the surface state may be partial, so it is discarded and the VT bytes
    /// are replayed into a fresh surface without Kitty state.
    private func restoreKittyReplay(_ replay: TerminalKittyReplay) {
        guard let lane = surfaceView.lane else { return }
        let target = ObjectIdentifier(surfaceView)
        lane.perform { [weak self] surface in
            let restored = replay.vt.withUnsafeBytes { buffer -> Bool in
                let aliases = replay.aliases.map {
                    ghostty_surface_kitty_image_alias(image_id: $0.imageID, image_number: $0.imageNumber)
                }
                let limits = ghostty_surface_kitty_graphics_limits(
                    image_bytes: replay.limits.imageBytes,
                    inflight_bytes: replay.limits.inflightBytes,
                    images: replay.limits.images,
                    placements: replay.limits.placements
                )
                let cursors = ghostty_surface_kitty_image_id_cursor_state(
                    replay: .init(primary: replay.replayCursors.primary, alternate: replay.replayCursors.alternate),
                    next: .init(primary: replay.nextCursors.primary, alternate: replay.nextCursors.alternate)
                )
                return aliases.withUnsafeBufferPointer { aliasBuffer in
                    ghostty_surface_restore_kitty_replay(
                        surface,
                        buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                        UInt(buffer.count),
                        replay.cursorOffset,
                        limits,
                        cursors,
                        aliasBuffer.baseAddress,
                        UInt(aliasBuffer.count)
                    )
                }
            }
            guard !restored else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, ObjectIdentifier(self.surfaceView) == target else { return }
                    GhosttyRuntime.logger.error("kitty replay restore failed; replaying VT without graphics state")
                    self.swapSurface()
                    self.surfaceView.lane?.processOutput(replay.vt)
                }
            }
        }
    }

    /// Resizes the live mirror to the daemon's grid in stream order: output
    /// queued before this event is parsed first, so Ghostty reflows the same
    /// screen the daemon reflowed.
    private func applyCanonicalGrid(_ grid: TerminalGridSize) async {
        canonicalGrid = grid
        if ownsGeometry, let index = recentReports.firstIndex(of: grid), index < recentReports.count - 1 {
            recentReports.removeFirst(index + 1)
            return
        }
        // Parse queued output at the old grid first; skip the wait when the
        // grid is already right (the echo of this view's own report). The
        // event loop is suspended meanwhile, so later output stays behind
        // this grid change, and the main thread keeps running.
        if surfaceView.currentGrid != grid, let lane = surfaceView.lane { await lane.drained() }
        surfaceView.applyCanonicalGrid(grid)
    }

    /// Ghostty has no reset API, so a new replay goes into a new surface
    /// that takes the old one's place (cmux-tui-contract.md 3.2).
    private func swapSurface() {
        let old = surfaceView
        let wasFirstResponder = old.isFirstResponder
        let fresh = TerminalSurfaceView(io: ioMode, input: input, session: self)
        fresh.ownsGeometry = ownsGeometry
        fresh.isRenderingSuspended = isRenderingSuspended
        fresh.mirrorDemand = mirrorDemand
        surfaceView = fresh
        view.install(fresh)
        // Nothing was parsed into the fresh surface yet: no drain needed.
        if let canonicalGrid { fresh.applyCanonicalGrid(canonicalGrid) }
        if wasFirstResponder { fresh.window?.makeFirstResponder(fresh) }
        surfaceHasContent = false
    }

    // MARK: From the surface view

    func surfaceDidReport(grid: TerminalGridSize, pixelWidth: Int, pixelHeight: Int) {
        guard ownsGeometry else { return }
        recentReports.removeAll { $0 == grid }
        recentReports.append(grid)
        if recentReports.count > 4 { recentReports.removeFirst() }
        input.resize(grid, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

/// Container the App embeds. Holds the current surface view (swapped on
/// replay) and paints the config background behind a follower grid that is
/// smaller than the view.
public final class TerminalHostView: NSView {
    private weak var current: TerminalSurfaceView?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ surfaceView: TerminalSurfaceView) {
        let old = current
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
        current = surfaceView
        old?.removeFromSuperview()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.cgColor
    }
}
