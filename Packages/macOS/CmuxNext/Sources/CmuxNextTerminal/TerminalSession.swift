public import AppKit
public import CmuxNextTerminalFind
import CmuxNextWakeups
import GhosttyNextKit

/// One terminal on screen: a Ghostty surface fed by a ``TerminalIO``.
///
/// Embed ``view``. The session consumes `io.events` off the main actor: live
/// output goes straight to a serial off-main output lane, every other event
/// is handled on the main actor in stream order. It writes Ghostty's
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
    public weak var delegate: (any TerminalSessionDelegate)? {
        didSet { linkCheck = delegate?.terminalSessionLinkCheck(self) }
    }

    /// The live surface. Replaced when a later VT replay arrives; a GHOSTSNP
    /// snapshot restores in place.
    public private(set) var surfaceView: TerminalSurfaceView

    public var ownsGeometry: Bool {
        didSet { surfaceView.ownsGeometry = ownsGeometry }
    }

    /// The grid a new terminal in this terminal's pane would fit: this view's
    /// fitted grid while it is in a window at the configured font size. Nil
    /// before its first layout, out of a window, or with its font zoomed (a
    /// new terminal starts at the configured size).
    public var gridForNewTerminal: TerminalGridSize? {
        guard surfaceView.window != nil, TerminalFontScale(surfaceView).current == nil else { return nil }
        return surfaceView.fittedGrid
    }

    /// Ghostty's cell size in backing pixels at the configured font size, for
    /// working out a new terminal's grid (``TerminalGridEstimate``). Nil while
    /// unknown or with this terminal's font zoomed.
    public var configuredCellPixelSize: CGSize? {
        let cell = model.cellPixelSize
        guard cell.width > 0, cell.height > 0, TerminalFontScale(surfaceView).current == nil else { return nil }
        return cell
    }

    /// Why a dead terminal's host was lost (nil: its process ended, or it runs).
    public var hostLoss: TerminalHostLoss? {
        didSet { if hostLoss != oldValue { view.showHostLoss(hostLoss, cause: hostLossCause) } }
    }

    /// What the lost host left as evidence (who signalled it, whether it had
    /// panicked), shown after the reason. Set it before `hostLoss`.
    public var hostLossCause: TerminalHostLossCause? {
        didSet { if hostLossCause != oldValue { view.showHostLoss(hostLoss, cause: hostLossCause) } }
    }

    /// The daemon reports the shell's host link down (tab `terminal_state`):
    /// the banner names it instead of leaving a silent last screen.
    public var shellStall: TerminalShellStall? {
        didSet { if shellStall != oldValue { view.showShellStall(shellStall) } }
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
        applyTheme(to: surfaceView, clearing: previous != nil && config == nil, animated: true)
    }

    /// Mirrors currently shown. Forwarded to whichever surface is live so a
    /// hover preview stays live across a surface swap.
    var mirrorDemand = 0 {
        didSet { surfaceView.mirrorDemand = mirrorDemand }
    }

    let io: any TerminalIO
    private let ioMode: ghostty_surface_io_mode_e
    private let input: TerminalInputSink
    private var eventsTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    /// Tasks an owner ties to this session's lifetime: ``close()`` cancels them.
    public var closeCancels: [Task<Void, Never>] = []
    /// Latest `.resize` grid, re-applied to a swapped-in surface.
    private var canonicalGrid: TerminalGridSize?
    /// True once the current surface received a replay or output; a later
    /// replay then needs a fresh surface.
    private(set) var surfaceHasContent = false
    let frameHold = TerminalFrameHold()
    /// READY snapshots restored in place, and surfaces swapped in for a
    /// later VT replay (diagnostics: a snapshot attach never swaps).
    private(set) var restoredSnapshots = 0
    private(set) var swappedSurfaces = 0
    /// Last frames shown while this session attached (``showLastFrame(_:)``).
    private(set) var lastFrameHolds = 0
    /// Local-history restores whose history did not match the owner's (or
    /// failed): each one asked the owner for READY + history.
    private(set) var localHistoryMismatches = 0
    /// Local-history READYs restored with the surface's own reflowed history
    /// (proves the local path ran in dogfood).
    private(set) var localSnapshots = 0
    /// Kitty images the owner left out of its image replays (its cap).
    private(set) var skippedImages = 0

    public init(io: any TerminalIO, ownsGeometry: Bool = true) {
        self.io = io
        self.ownsGeometry = ownsGeometry
        ioMode = io.answersTerminalQueries ? GHOSTTY_SURFACE_IO_MANUAL_MIRROR : GHOSTTY_SURFACE_IO_MANUAL

        // concurrency-allow: carries only user input and resizes, produced at human rate
        let (outgoing, continuation) = AsyncStream<TerminalOutgoing>.makeStream(bufferingPolicy: .unbounded)
        input = TerminalInputSink(continuation: continuation)

        view = TerminalHostView()
        surfaceView = TerminalSurfaceView(io: ioMode, input: input, session: nil)
        surfaceView.bridge.takeUnretainedValue().installLinkFilter(nil)
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
                case .takeOverSize(let setLatest):
                    await io.takeOverSize(setLatest: setLatest)
                case .reconnect:
                    await io.reconnectRequested()
                case .resync:
                    await io.resyncRequested()
                }
            }
        }

        eventsTask = Self.consume(io.events, probeSource: io.typingProbeSource, for: self)
        // The first grid report fired inside the surface init, before
        // `session` was set; report it now.
        surfaceView.updateSurfaceSize(forceReport: true)
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { traceSurfaceCreated(io: io) }
        #endif
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Sendable cleanup only, so it runs on whatever thread releases the session.
    nonisolated deinit {
        eventsTask?.cancel()
        writerTask?.cancel()
        input.finish()
    }

    // MARK: Public API

    /// Makes the surface first responder.
    public func focus() {
        surfaceView.window?.makeFirstResponder(surfaceView)
    }

    /// Whether a text Ghostty detected as a link under a Cmd-hover is one (cx-do47.1): a path
    /// that names no file is plain text, with no underline and no open. Gets the text and the
    /// folder the shell last reported; runs off the main thread. Nil: every detected link is one.
    public private(set) var linkCheck: TerminalLinkCheck? {
        didSet { surfaceView.bridge.takeUnretainedValue().linkFilter.setCheck(linkCheck) }
    }

    #if DEBUG
    /// Moves the pointer over viewport cell (`column`, `row`) as a mouse does, with
    /// `flags` held (live checks): the view's own mouse-move path.
    public func hoverLinkForTesting(column: Int, row: Int, flags: NSEvent.ModifierFlags = .command) {
        guard let event = surfaceView.linkTestEvent(.mouseMoved, column: column, row: row, flags: flags) else { return }
        surfaceView.linkPointer.testPointer = surfaceView.convert(event.locationInWindow, from: nil)
        surfaceView.linkPointer.testFlags = flags
        surfaceView.mouseMoved(with: event)
    }

    /// A left click on viewport cell (`column`, `row`) with `flags` held, through the
    /// view's own press and release handlers (live checks).
    public func clickLinkForTesting(column: Int, row: Int, flags: NSEvent.ModifierFlags = .command) {
        guard let down = surfaceView.linkTestEvent(.leftMouseDown, column: column, row: row, flags: flags),
              let up = surfaceView.linkTestEvent(.leftMouseUp, column: column, row: row, flags: flags) else { return }
        surfaceView.linkPointer.testPointer = surfaceView.convert(down.locationInWindow, from: nil)
        surfaceView.linkPointer.testFlags = flags
        surfaceView.mouseDown(with: down)
        surfaceView.mouseUp(with: up)
    }

    /// A left press on one cell, a drag to another and the release there, with `flags`
    /// held throughout (live checks).
    public func dragForTesting(from: (column: Int, row: Int), to: (column: Int, row: Int), flags: NSEvent.ModifierFlags = .command) {
        guard let down = surfaceView.linkTestEvent(.leftMouseDown, column: from.column, row: from.row, flags: flags),
              let drag = surfaceView.linkTestEvent(.leftMouseDragged, column: to.column, row: to.row, flags: flags),
              let up = surfaceView.linkTestEvent(.leftMouseUp, column: to.column, row: to.row, flags: flags) else { return }
        surfaceView.linkPointer.testPointer = surfaceView.convert(down.locationInWindow, from: nil)
        surfaceView.linkPointer.testFlags = flags
        surfaceView.mouseDown(with: down)
        surfaceView.linkPointer.testPointer = surfaceView.convert(drag.locationInWindow, from: nil)
        surfaceView.mouseDragged(with: drag)
        surfaceView.mouseUp(with: up)
    }

    /// Modifier keys went down or up with the pointer still (live checks): the key path
    /// when this terminal has focus, the app-wide watcher's either way.
    public func modifiersChangedForTesting(_ flags: NSEvent.ModifierFlags) {
        surfaceView.linkPointer.testFlags = flags
        // A Command key event as AppKit delivers it: flagsChanged, left Command (key code 55).
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: flags.contains(.command))
        key?.type = .flagsChanged
        key?.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if surfaceView.isFirstResponder, let key, let event = NSEvent(cgEvent: key) {
            surfaceView.flagsChanged(with: event)
        }
        surfaceView.linkPointer.modifiersChanged(flags)
    }

    /// The wrapped link under the pointer and whether the pointer shows the pointing hand.
    public var linkPointerStateForTesting: (wrapped: String?, pointingHand: Bool) {
        (surfaceView.linkPointer.wrapped?.text, surfaceView.cursor == .pointingHand)
    }
    #endif

    /// Activates `text` as a Cmd-click on a link Ghostty detected does (its `open_url` action).
    @discardableResult
    public func activateLink(_ text: String) -> Bool {
        surfaceView.applyAction(.openURL(text))
    }

    /// Sends bytes as typed, in order with this terminal's keys (they join the same queue to
    /// `io.write`): input the daemon gave back from a creation that did not take it.
    public func sendBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        input.send(data)
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

    /// A new session for an evicted terminal: its last frame shows at once, until the first
    /// content the owner sends is parsed and drawn (no empty pane while it attaches). Returns
    /// why it did not (diagnostics), nil when it holds the frame.
    @discardableResult
    public func showLastFrame(_ frame: TerminalLastFrame) -> String? {
        guard !surfaceHasContent else { return "has_content" }
        guard let surface = frame.take() else { return "purged" }
        lastFrameHolds += 1
        frameHold.begin(lastFrame: surface, over: surfaceView, in: view)
        return nil
    }

    /// ``snapshot(maxPixelSize:)`` rendered off the main thread (it waits on the GPU).
    public func snapshotInBackground(maxPixelSize: CGFloat = 480) async -> CGImage? {
        await surfaceView.snapshotInBackground(maxPixelSize: maxPixelSize)
    }

    /// Stops consuming events and detaches the surface. The IO owner decides
    /// whether the underlying terminal keeps running.
    public func close() {
        surfaceView.clipboardRequests.cancelPendingWrite()
        eventsTask?.cancel()
        eventsTask = nil
        closeCancels.forEach { $0.cancel() }
        closeCancels = []
        input.finish()
        surfaceView.removeFromSuperview()
    }

    // MARK: Events

    /// Consumes `events` off the main actor. Output for a surface that already has content goes
    /// straight to its output lane: a busy terminal costs the main thread nothing per chunk, and an
    /// echo never waits behind other terminals' output or a motion frame on main. Every other event
    /// (a replay, a snapshot, a grid, a status, a surface's first content) is handled on the main
    /// actor, in stream order: the loop waits for it, and it hands back the lane the next output
    /// may use (nil while the surface still waits for its first content, or none is live). Only
    /// ``handle(_:)`` swaps surfaces, so that lane stays current until the next main-actor event.
    /// `probeSource` names the IO's terminal to the typing probe (``TerminalIO/typingProbeSource``).
    private nonisolated static func consume(_ events: AsyncStream<TerminalIOEvent>, probeSource: TypingLatencyProbe.Source?,
                                            for session: TerminalSession) -> Task<Void, Never> {
        Task.detached(priority: .high) { [weak session] in
            var lane: TerminalOutputLane?
            for await event in events {
                if case .output(let data) = event, let lane {
                    TypingLatencyProbe.shared.mark(.outputReceived, source: probeSource, next: .object(ObjectIdentifier(lane)))
                    ExpectedActivity.shared.note(.terminalOutput)
                    await lane.waitForCapacity()
                    lane.processOutput(data)
                    continue
                }
                guard let session else { return }
                lane = await session.handle(event)
            }
        }
    }

    /// Handles one event on the main actor. Returns the lane later output may go to off the main
    /// actor (``consume(_:for:)``).
    private func handle(_ event: TerminalIOEvent) async -> TerminalOutputLane? {
        await apply(event)
        return surfaceHasContent ? surfaceView.lane : nil
    }

    private func apply(_ event: TerminalIOEvent) async {
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { traceEvent(event) }
        #endif
        switch event {
        case .replay(let data):
            if surfaceHasContent { swapSurface() }
            surfaceView.lane?.processOutput(data)
            surfaceHasContent = true
            frameHold.contentQueued()
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
            frameHold.contentQueued()
            TerminalTimings.contentApplied()
        case .snapshot(let data, let phase):
            // The same surface takes the owner's state: no swap.
            let restored = await restoreSnapshot(data, phase: phase)
            guard restored, phase.isReady else { return }
            restoredSnapshots += 1
            surfaceHasContent = true
            frameHold.contentQueued()
            TerminalTimings.contentApplied()
        case .output(let data):
            TypingLatencyProbe.shared.mark(.outputReceived, source: io.typingProbeSource,
                                           next: surfaceView.lane.map { .object(ObjectIdentifier($0)) })
            ExpectedActivity.shared.note(.terminalOutput)
            guard let lane = surfaceView.lane else { return }
            await lane.waitForCapacity()
            // The surface may have been swapped while waiting (a replay).
            surfaceView.lane?.processOutput(data)
            surfaceHasContent = true
            frameHold.contentQueued()
            TerminalTimings.contentApplied()
        case .resize(let columns, let rows):
            guard columns > 0, rows > 0 else { return }
            await applyCanonicalGrid(TerminalGridSize(columns: columns, rows: rows))
        case .exited:
            model.hasExited = true
        case .status(let status):
            model.connection = status
            model.hasExited = status == .exited
            surfaceView.updateReflowPreview()
            view.showStatus(status)
            // A disconnected or exited view no longer knows who sets the grid.
            if status != .connected { view.showSizedFor(nil) }
        case .sizedFor(let sizedFor):
            view.showSizedFor(model.connection == .connected ? sizedFor : nil)
        }
    }

    /// Take over ("Sized for" chip): this view sets the grid, always with a new claim; under a
    /// policy that picks by size the terminal becomes last active first.
    func takeOverSize(setLatest: Bool) {
        input.takeOverSize(setLatest: setLatest)
    }

    /// A click in the surface: a disconnected terminal re-attaches now, also
    /// one waiting out its backoff between retries.
    func surfaceClicked() {
        guard case .disconnected = model.connection else { return }
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
        old.clipboardRequests.cancelPendingWrite()
        let wasFirstResponder = old.isFirstResponder
        let fresh = TerminalSurfaceView(io: ioMode, input: input, session: self)
        swappedSurfaces += 1
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { traceSurfaceSwapped(fresh) }
        #endif
        fresh.ownsGeometry = ownsGeometry
        fresh.isRenderingSuspended = isRenderingSuspended
        fresh.mirrorDemand = mirrorDemand
        surfaceView = fresh
        fresh.bridge.takeUnretainedValue().installLinkFilter(linkCheck)
        fresh.bridge.takeUnretainedValue().linkFilter.setWorkingDirectory(model.workingDirectory)
        view.install(fresh)
        frameHold.begin(old: old, fresh: fresh, in: view) // no empty frame until the fresh one draws (cx-6so.23)
        applyTheme(to: fresh, clearing: false, animated: false)
        TerminalFontScale(old).carry(to: fresh) // after the theme: its config update can reset the size
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
    /// `animated`: the live surface blends to the new colors on the GPU from the colors on
    /// screen (a theme change); a fresh surface takes its first colors at once.
    private func applyTheme(to surfaceView: TerminalSurfaceView, clearing: Bool, animated: Bool) {
        guard let surface = surfaceView.surface else { return }
        surfaceView.applyColorTransition(animated: animated)
        if let theme {
            ghostty_surface_update_config(surface, theme.config)
        } else if clearing, let config = GhosttyRuntime.shared.config {
            ghostty_surface_update_config(surface, config)
        }
    }

    // MARK: From the surface view

    func noteSkippedImages(_ count: Int) {
        skippedImages += max(0, count)
    }

    func noteLocalSnapshot() {
        localSnapshots += 1
    }

    func noteLocalHistoryMismatch() {
        localHistoryMismatches += 1
        input.resync()
    }

    func surfaceDidGainFocus() {
        input.focusGained()
    }

    /// The surface reports its grid to the PTY owner. `final`: the grid its pane's layout spring will
    /// land at (``TerminalIO/resizeOnMain(cols:rows:final:window:)``).
    func surfaceDidReport(grid: TerminalGridSize, pixelWidth: Int, pixelHeight: Int, final: Bool = false) {
        guard ownsGeometry else { return }
        // An IO with a main-actor path takes every grid there, so a final grid never overtakes, or
        // is overtaken by, an older grid still in the ordered input stream.
        if io.resizeOnMain(cols: grid.columns, rows: grid.rows, final: final, window: surfaceView.window) { return }
        input.resize(grid, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
