public import AppKit
public import CmuxNextTerminalFind
public import CmuxNextTrace
public import CmuxNextWakeups
import CmuxNextCompat
import GhosttyNextKit

/// One terminal on screen: a Ghostty surface fed by a ``TerminalIO``.
///
/// Embed ``view``. The session consumes `io.events` off the main actor and
/// never waits for it (``TerminalEventRouter``): output, grid locks and
/// snapshot restores go straight to a serial off-main output lane, and what
/// the main actor shows (grid, status, chip, content) is applied once per
/// frame (``TerminalEventMailbox``). Only a replay into a surface with
/// content takes the main actor, which swaps in a fresh surface. Ghostty's encoded input,
/// grid reports and focus go to the IO in order through one
/// ``TerminalInputLane`` drained on the IO's queue (`io.inputDrain()`), one
/// thread hop from the key. Consumption is demand-driven:
/// the next event is taken only once the lane has room, so a slow parser
/// pushes back on the IO (which bounds its own buffer) instead of queueing
/// without limit (state-audit.md T1).
///
/// Geometry: the mirror's grid must equal the PTY's grid at every point in
/// the byte stream, or later output lands in the wrong cells. The IO owner
/// decides the PTY size; every `.resize` event locks the live surface's grid
/// in place (`ghostty_surface_set_grid`, queued on the output lane behind
/// every earlier chunk, at the lane's generation), and never replaces the surface. Once one arrived the surface
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

    /// Outside the keep-alive band (the App's surface ledger): paused, the surface lets its GPU memory
    /// go (``TerminalGPUResidencyGate``); in the band it keeps it, so scrolling back reallocates nothing.
    public var releasesGPUWhilePaused = false {
        didSet { surfaceView.releasesGPUWhilePaused = releasesGPUWhilePaused }
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
    /// Passed to each surface view this session makes, the first and every swapped-in one.
    private let hangWatch: (any HangWatchScoping)?
    /// Passed to each surface view this session makes: their secure keyboard entry requests.
    private let secureInput: TerminalSecureInput
    /// Passed to each surface view this session makes: the terminals' one modifier watch.
    private let modifiers: TerminalModifierWatch?
    /// Passed to each surface view this session makes: the windows' frame-aligned pointer input.
    private let pointerFrames: FrameInputCoalescers?
    /// Passed to each surface view this session makes: their GPU memory release while away.
    private let gpuResidency: (any TerminalGPUResidency)?
    /// Passed to each surface view this session makes: the cursor on the render server (``TerminalCursorLayer``).
    private let externalCursor: Bool
    /// Passed to each surface view this session makes: a hidden view's output parses at utility.
    private let lowersHiddenOutput: Bool
    private let input: TerminalInputSink
    /// The lane the IO's reader feeds live output to (``TerminalIO/setOutputLane(_:)``): the events loop
    /// names it, close names none.
    let outputLane: TerminalOutputLaneNamer
    private let echoStages: TerminalEchoStages
    /// What the events loop changed for the main actor, applied once per frame (``applyEvents()``).
    let events: TerminalEventMailbox
    private var eventsTask: Task<Void, Never>?
    var createStages = NewTerminalTrace.CreateStages() // the new tab's create.tab while it waits (traceCreate)
    /// Tasks an owner ties to this session's lifetime: ``close()`` cancels them.
    public var closeCancels: [Task<Void, Never>] = []
    /// Latest `.resize` grid, re-applied to a swapped-in surface.
    private var canonicalGrid: TerminalGridSize?
    /// True once the current surface received a replay or output; a later
    /// replay then needs a fresh surface.
    private(set) var surfaceHasContent = false
    let frameHold: TerminalFrameHold
    /// READY snapshots restored in place, and surfaces swapped in for a later VT replay (diagnostics: a snapshot attach never swaps).
    private(set) var restoredSnapshots = 0
    private(set) var swappedSurfaces = 0
    /// Last frames shown while this session attached (``showLastFrame(_:)``).
    private(set) var lastFrameHolds = 0
    /// Local-history restores whose history did not match the owner's (or failed): each one asked the owner for READY + history.
    private(set) var localHistoryMismatches = 0
    /// Local-history READYs restored with the surface's own reflowed history
    /// (proves the local path ran in dogfood).
    private(set) var localSnapshots = 0
    /// Kitty images the owner left out of its image replays (its cap).
    private(set) var skippedImages = 0

    /// - Parameters:
    ///   - echoStages: Where its surfaces' key-to-echo stages go (``TerminalEchoStages``).
    ///   - hangWatch: watches each output chunk's parse on the surface's output lane; the app's
    ///     composition root passes its ``HangWatch``. nil watches nothing.
    ///   - secureInput: The process's secure keyboard entry, which its surfaces turn on for Ghostty.
    ///   - modifiers: The terminals' one modifier watch (``TerminalModifierWatch``): Command pressed or
    ///     released over a surface without focus reaches it. The App passes its one; nil reaches none.
    ///   - pointerFrames: The windows' frame-aligned pointer input (feature `terminalPointerFrames`): its
    ///     surfaces send moves, drags and mouse-reporting trackpad scrolls to Ghostty on a frame interval's
    ///     first event and once more at its frame (``TerminalPointerFrames``). Nil: every event at once.
    ///   - mainWork: The app's main-thread scheduler, `node` the tab's node (`TabContentCache.node(for:)`; nil: no tab) and `deadlines`
    ///     its `MainDeadline` placer (nil makes one): the find bar, scrollbar, TextBox and window watches apply only while it shows,
    ///     and its surfaces size and report grids only while the node is not hidden (R-hide).
    ///   - gpuResidency: Lets the surfaces' GPU memory go while ``releasesGPUWhilePaused`` and paused;
    ///     nil keeps them resident (a GhosttyNextKit pin without the switch, or `terminalGPURelease` off).
    ///   - externalCursor: Its surfaces show the cursor on a layer of their own and blink it in the render server
    ///     (feature `terminalCursorLayer`, ``TerminalCursorLayer``); false: Ghostty draws and blinks it.
    ///   - lowersHiddenOutput: A hidden surface's output parses at utility (feature `terminalStreamPriority`);
    ///     false, the default, parses every surface's at user-interactive.
    public init(io: any TerminalIO, ownsGeometry: Bool = true,
                echoStages: TerminalEchoStages = GhosttyRuntime.shared.echoStages,
                hangWatch: (any HangWatchScoping)? = nil,
                secureInput: TerminalSecureInput = GhosttyRuntime.shared.secureInput,
                modifiers: TerminalModifierWatch? = nil, pointerFrames: FrameInputCoalescers? = nil,
                mainWork: MainWorkScheduler, node: VisibilityNode? = nil, deadlines: MainDeadlineScheduler? = nil,
                gpuResidency: (any TerminalGPUResidency)? = nil, externalCursor: Bool = false,
                lowersHiddenOutput: Bool = false) {
        self.io = io
        self.ownsGeometry = ownsGeometry
        self.echoStages = echoStages
        self.hangWatch = hangWatch
        self.secureInput = secureInput
        self.modifiers = modifiers
        self.pointerFrames = pointerFrames
        self.gpuResidency = gpuResidency
        self.externalCursor = externalCursor
        self.lowersHiddenOutput = lowersHiddenOutput
        ioMode = io.answersTerminalQueries ? GHOSTTY_SURFACE_IO_MANUAL_MIRROR : GHOSTTY_SURFACE_IO_MANUAL

        // One hop from the main thread to the IO's own queue (``TerminalInputLane``), no pool task.
        outputLane = TerminalOutputLaneNamer(io: io)
        input = TerminalInputSink(lane: TerminalInputLane(drain: io.inputDrain()), typingSurface: TypingLatencyProbe.shared.makeSurfaceKey())

        frameHold = TerminalFrameHold(deadlines: deadlines ?? MainDeadlineScheduler(work: mainWork))
        // node-free: the model's connection, grid and content are read while the tab is hidden
        // (its sidebar status, a click's reconnect, the frame hold); the view work it does is a
        // chip and a banner, once per frame at most.
        let target = EventsTarget(), owner = mainWork.board.owner("terminal.events")
        events = TerminalEventMailbox { [mainWork] in
            mainWork.postFromAnyThread(.visible, owner: owner) { target.session?.applyEvents() }
        }

        view = TerminalHostView(mainWork: mainWork, node: node)
        surfaceView = TerminalSurfaceView(io: ioMode, input: input, session: nil, echoStages: echoStages, hangWatch: hangWatch,
                                          secureInput: secureInput, modifiers: modifiers, pointerFrames: pointerFrames,
                                          mainWork: mainWork, node: node, gpuResidency: gpuResidency,
                                          externalCursor: externalCursor, lowersHiddenOutput: lowersHiddenOutput)
        surfaceView.bridgeObject.installLinkFilter(nil)
        surfaceView.session = self
        surfaceView.ownsGeometry = ownsGeometry
        view.install(surfaceView)
        find.target = self
        view.attachFind(find)

        target.session = self
        eventsTask = Self.consume(io.events, from: io, with: TerminalEventRouter(
            lane: surfaceView.lane, mailbox: events, input: input, outputLane: outputLane,
            replace: { [weak self] event -> TerminalOutputLane?? in
                guard let self else { return nil }
                return await self.replace(event)
            }))
        // The first grid report fired inside the surface init, before
        // `session` was set; report it now.
        surfaceView.updateSurfaceSize(forceReport: true)
        traceSurfaceCreated(io: io) // DEBUG: `debug.new_terminal_trace` (Release: the cache's traceCreate)
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Sendable cleanup only, so it runs on whatever thread releases the session.
    nonisolated deinit {
        eventsTask?.cancel()
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
        didSet { surfaceView.bridgeObject.linkFilter.setCheck(linkCheck) }
    }

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
        // SAFETY: the view's live surface (TerminalSurfaceView.surface); Swift passes a NUL-terminated
        // copy of `text` for the call, its length without the NUL, and Ghostty copies what it keeps.
        unsafe ghostty_surface_text(surface, text, UInt(text.utf8.count))
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
        applyEvents()
        guard !surfaceHasContent else { return "has_content" }
        guard let surface = frame.take() else { return "purged" }
        lastFrameHolds += 1
        frameHold.begin(lastFrame: .surface(surface), over: surfaceView, in: view)
        return nil
    }

    /// What this session's pane shows now, for a session that replaces it on the same tab (a daemon restart
    /// gives the terminal a new generation, so the App makes a new view of it): the held frame while a hold
    /// is on screen, else the surface's last presented frame once it drew content; nil when it shows nothing.
    /// A surface frame is made non-volatile here and given away: this session, closed next, never marks it
    /// volatile again (``TerminalHeldFrame/giveAway(_:)``); nil when the system purged its pages meanwhile.
    public func carriedFrame() -> TerminalCarriedFrame? {
        let frame: TerminalFrameHold.HeldFrame
        if let held = frameHold.heldFrame {
            frame = held
        } else if surfaceHasContent, let surface = surfaceView.presentedFrame {
            frame = .surface(surface)
        } else {
            return nil
        }
        if case .surface(let surface) = frame {
            surfaceView.heldFrame.giveAway(surface)
            guard surface.reclaim() else { return nil }
        }
        return TerminalCarriedFrame(frame: frame)
    }

    /// Shows `frame` (``carriedFrame()`` of the session this one replaces) until this session's first content
    /// is drawn, as a launch or evicted terminal's last frame is: no empty pane between the two views.
    /// Returns false when this session has content or holds a frame already.
    @discardableResult
    public func holdCarriedFrame(_ frame: TerminalCarriedFrame) -> Bool {
        applyEvents()
        guard !surfaceHasContent, !frameHold.isHolding else { return false }
        lastFrameHolds += 1
        frameHold.begin(lastFrame: frame.frame, over: surfaceView, in: view)
        return true
    }

    /// ``snapshot(maxPixelSize:)`` rendered off the main thread (it waits on the GPU).
    public func snapshotInBackground(maxPixelSize: CGFloat = 480) async -> CGImage? {
        await surfaceView.snapshotInBackground(maxPixelSize: maxPixelSize)
    }

    /// What the pane shows now, rendered off the main thread: while the frame hold is on screen (a restored or
    /// evicted terminal whose attach has not drawn its content yet), the held frame, never the empty surface under
    /// it; else ``snapshotInBackground(maxPixelSize:)``. The quit saves this for the next launch, and the hover card
    /// pictures it: a quit during a slow attach must not save an empty pane as the terminal's last frame.
    public func shownFrameInBackground(maxPixelSize: CGFloat = 480) async -> CGImage? {
        switch frameHold.heldFrame {
        case nil:
            return await snapshotInBackground(maxPixelSize: maxPixelSize)
        case .image(let image)?:
            return image
        case .surface(let surface)?:
            return await TerminalSnapshotRenderer.renderOffMain(SendableSurface(surface: surface), maxPixelSize: maxPixelSize)
        }
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
        outputLane.close() // the IO's reader feeds no lane of this session again
        surfaceView.removeFromSuperview()
    }

    // MARK: Events

    /// Consumes `events` off the main actor (``TerminalEventRouter``): the loop never waits for the
    /// main actor except to swap in a fresh surface for a replay into one with content.
    /// Each output chunk, once routed, is credited back to `io` (``TerminalIO/outputConsumed(_:)``),
    /// so an IO that bounds its stream reads on.
    private nonisolated static func consume(_ events: AsyncStream<TerminalIOEvent>, from io: any TerminalIO,
                                            with router: TerminalEventRouter) -> Task<Void, Never> {
        Task.detached(priority: .high) {
            var router = router
            for await event in events {
                defer { if case .output(let data) = event { io.outputConsumed(data.count) } }
                guard await router.route(event) else { return }
            }
        }
    }

    /// A replay into a surface with content: what the loop posted before it applies first, then a
    /// fresh surface takes the old one's place and the replay is queued on its lane. Returns that
    /// lane, for the loop's later events.
    private func replace(_ event: TerminalIOEvent) -> TerminalOutputLane? {
        applyEvents()
        swapSurface()
        switch event {
        case .replay(let data): surfaceView.lane?.processOutput(data)
        case .kittyReplay(let replay): surfaceView.lane?.processOutput(replay.vt)
        default: break
        }
        contentQueued()
        return surfaceView.lane
    }

    /// Applies what the events loop and the lane changed since the last pass, in one main turn:
    /// on the frame the mailbox asked for, or first thing before a surface swap.
    func applyEvents() {
        guard let pending = events.take() else { return }
        if let grid = pending.grid {
            // Its lock is already on the lane, in stream order; the view follows it here.
            canonicalGrid = grid
            surfaceView.applyAnnouncedGrid(grid)
        }
        if let status = pending.status {
            model.connection = status
            model.hasExited = status == .exited
            surfaceView.updateReflowPreview()
            view.showStatus(status)
        }
        if pending.exited { model.hasExited = true }
        if let sizedFor = pending.sizedFor {
            view.showSizedFor(model.connection == .connected ? sizedFor : nil)
        }
        restoredSnapshots += pending.readyRestores
        localSnapshots += pending.localSnapshots
        localHistoryMismatches += pending.localHistoryMismatches
        skippedImages += pending.skippedImages
        if pending.contentQueued { contentQueued() }
    }

    /// Takes a holder of ``events`` back to the session on the main actor, without retaining it.
    @MainActor private final class EventsTarget {
        weak var session: TerminalSession?
    }

    /// Content reached the live surface's lane: the frame hold waits for it to be drawn.
    private func contentQueued() {
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contentOnMain(session: ObjectIdentifier(self)) }
        #endif
        surfaceHasContent = true
        frameHold.contentQueued()
        TerminalTimings.contentApplied(self)
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

    /// Ghostty has no reset API, so a new replay goes into a new surface
    /// that takes the old one's place (cmux-tui-contract.md 3.2).
    private func swapSurface() {
        let old = surfaceView
        applyWaitingActions() // the old surface's held pwd and progress: the fresh one starts from the model
        old.clipboardRequests.cancelPendingWrite()
        let wasFirstResponder = old.isFirstResponder
        let fresh = TerminalSurfaceView(io: ioMode, input: input, session: self, echoStages: echoStages, hangWatch: hangWatch,
                                        secureInput: secureInput, modifiers: modifiers, pointerFrames: pointerFrames,
                                        mainWork: view.mainWork, node: view.node, gpuResidency: gpuResidency,
                                        externalCursor: externalCursor, lowersHiddenOutput: lowersHiddenOutput)
        swappedSurfaces += 1
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { traceSurfaceSwapped(fresh) }
        #endif
        fresh.ownsGeometry = ownsGeometry
        // The draw demand first: a fresh surface a live mirror draws is never released, even for one turn.
        fresh.mirrorDemand = mirrorDemand
        fresh.isRenderingSuspended = isRenderingSuspended
        fresh.releasesGPUWhilePaused = releasesGPUWhilePaused
        surfaceView = fresh
        fresh.bridgeObject.installLinkFilter(linkCheck)
        fresh.bridgeObject.linkFilter.setWorkingDirectory(model.workingDirectory)
        view.install(fresh)
        frameHold.begin(old: old, fresh: fresh, in: view) // no empty frame until the fresh one draws (cx-6so.23)
        applyTheme(to: fresh, clearing: false, animated: false)
        TerminalFontScale(old).carry(to: fresh) // after the theme: its config update can reset the size
        // Nothing was parsed into the fresh surface yet: its lock goes first on its lane.
        if let canonicalGrid {
            fresh.lane?.lockGrid(canonicalGrid)
            fresh.applyAnnouncedGrid(canonicalGrid)
        }
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
            // SAFETY: the view's live surface (TerminalSurfaceView.surface) and the theme's live
            // config, which `theme` holds for the call; Ghostty copies what it keeps.
            unsafe ghostty_surface_update_config(surface, theme.config)
        } else if clearing, let config = GhosttyRuntime.shared.config {
            // SAFETY: as above, with the runtime's live applied config (GhosttyRuntime.config).
            unsafe ghostty_surface_update_config(surface, config)
        }
    }

    // MARK: From the surface view

    func surfaceDidGainFocus() {
        io.streamFocusGained()
        input.focusGained()
    }

    /// The surface reports its grid to the PTY owner. `final`: the grid its pane's layout spring will
    /// land at (``TerminalIO/resizeOnMain(cols:rows:final:window:)``).
    func surfaceDidReport(grid: TerminalGridSize, pixelWidth: Int, pixelHeight: Int, final: Bool = false) {
        guard ownsGeometry else { return }
        if final { traceFinalGrid(grid) } // a new tab's create.tab final_grid stage while it waits (NewTerminalTrace)
        // An IO with a main-actor path takes every grid there, so a final grid never overtakes, or
        // is overtaken by, an older grid still in the ordered input stream.
        if io.resizeOnMain(cols: grid.columns, rows: grid.rows, final: final, window: surfaceView.window) { return }
        input.resize(grid, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
