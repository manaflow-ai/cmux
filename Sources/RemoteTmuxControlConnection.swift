import Foundation
import os

/// A live tmux control-mode connection to one remote session.
///
/// Spawns `ssh -tt <ControlMaster> host tmux -CC attach -t <session>` as a
/// `Process` with pipes, feeds its stdout through ``RemoteTmuxControlStreamParser``
/// (in order, via an `AsyncStream`), and exposes the mirrored topology plus a
/// live output callback. cmux owns the whole protocol here — so it never depends
/// on ghostty's (tmux-3.6-fragile) built-in Viewer, and there is no
/// command-queue desync because we issue and correlate commands ourselves.
@MainActor
final class RemoteTmuxControlConnection {
    typealias ConnectionState = RemoteTmuxConnectionState
    typealias PaneForegroundState = RemoteTmuxPaneForegroundState
    typealias Snapshot = RemoteTmuxControlConnectionSnapshot
    private typealias CommandKind = RemoteTmuxControlCommandKind
    private typealias PostAttachAction = RemoteTmuxPostAttachAction

    /// The host this connection talks to.
    let host: RemoteTmuxHost
    /// The tmux session name this connection attaches to. Mutable because a
    /// `rename-session` changes it (the underlying `$id` is stable).
    private(set) var sessionName: String

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

    /// Opaque token identifying a registered observer (pass to ``removeObserver(_:)``).
    typealias ObserverToken = UUID

    /// Multicast observer registry. A single connection is shared by every consumer
    /// of the same host+session (``RemoteTmuxController.attach`` reuses it), so events
    /// fan out to all consumers via this registry.
    let observers = RemoteTmuxConnectionObservers()

    // MARK: Observed state

    private(set) var started = false
    private(set) var enterReceived = false
    /// The connection's lifecycle phase. Drives reconnect-on-transport-loss and the
    /// disconnected UI; `exited` is derived from it.
    private(set) var connectionState: ConnectionState = .connecting {
        didSet {
            guard oldValue != connectionState else { return }
            observers.notifyStateChanged(connectionState)
            switch connectionState {
            case .connected:
                finishConnectionWaiters(connected: true)
            case .ended:
                finishConnectionWaiters(connected: false)
            case .connecting, .reconnecting:
                break
            }
        }
    }
    /// `true` once the connection has permanently ended (genuine tmux `%exit`, a
    /// session discovered gone on reconnect, or a deliberate ``stop()``). A
    /// transient transport loss is `.reconnecting`, NOT ended — so callers that
    /// guard on `!exited` keep treating a reconnecting connection as alive.
    var exited: Bool { connectionState == .ended }
    private(set) var sessionId: Int?
    var windowsByID: [Int: RemoteTmuxWindow] = [:]
    var windowOrder: [Int] = []
    var activePaneByWindow: [Int: Int] = [:]
    var paneOutputByteCounts: [Int: Int] = [:]
    var totalOutputBytes = 0
    /// Last-known foreground classification per pane, kept current by the same
    /// one-shot query + live subscription that drive reflow classification
    /// (`#{alternate_on}` + `#{pane_current_command}`, see
    /// ``requestPaneReflow(paneId:)``). Read at close time to decide whether
    /// killing a mirrored pane/window needs a confirmation dialog — a mirror
    /// surface has no local child process for ghostty's needs-confirm check.
    var paneForegroundStates: [Int: PaneForegroundState] = [:]
    /// In-flight close-time activity queries by token (see
    /// ``queryWindowActivity(windowId:completion:)``). Failed with `nil` when the
    /// control stream becomes unusable, so a pending close decision falls back to
    /// the cached classification instead of hanging until a reconnect that may
    /// never come.
    var activityQueryCompletions: [UUID: ([Int: PaneForegroundState]?) -> Void] = [:]

    private var process: Process?
    private var stdinWriter: RemoteTmuxControlPipeWriter?
    private var stdoutReader: FileHandle?
    private var stderrReader: FileHandle?
    private var stdoutPipeReader: RemoteTmuxStdoutPipeReader?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    /// Consumes the current spawn's stderr into `stderrBuffer`. Awaited before a
    /// failed reconnect attempt is classified, so the decision sees the complete
    /// error rather than racing the async stderr delivery.
    private var stderrTask: Task<Void, Never>?
    private var parser = RemoteTmuxControlStreamParser()
    private var ingestTask: Task<Void, Never>?
    var pendingCommands: [CommandKind] = []
    private var connectionWaiters: [UUID: (Bool) -> Void] = [:]
    /// `false` until the attach command's own `%begin`/`%end` block — always the
    /// FIRST block on each control stream, preceding every notification — has been
    /// consumed. That first block is matched explicitly (see the `.commandResult`
    /// dispatch) rather than by "FIFO happens to be empty", so a command that races
    /// in early (e.g. a debounced size send on a stalled link) can never have its
    /// result slot stolen by the attach block. Reset per spawn (each ssh re-attach
    /// produces a fresh attach block).
    private var attachBlockDrained = false
    private let createIfMissing: Bool

    /// Stateless pure decoders for control-mode message payloads (pane-state seed,
    /// window reorder, session-gone classification). Holds no state.
    let decoding = RemoteTmuxControlMessageDecoding()
    /// Bounded ring of recent event labels surfaced through `remote.tmux.state`.
    private let diagnostics = RemoteTmuxConnectionDiagnostics()

    // MARK: Reconnect state

    /// The current reconnect backoff task (a single sleeping `Task` between
    /// attempts); cancelled on `stop()` / genuine end so a dead connection stops
    /// retrying.
    private var reconnectTask: Task<Void, Never>?
    /// Number of reconnect attempts since the last successful connect, driving the
    /// capped exponential backoff. Reset to 0 on a successful connect.
    private var reconnectAttemptCount = 0
    /// stderr text captured for the in-flight spawn, inspected when a reconnect
    /// attempt's process exits to tell "session genuinely gone" from "host still
    /// unreachable". Reset at the start of each spawn.
    private var stderrBuffer = ""
    /// Last client size applied via ``setClientSize(columns:rows:)``, re-applied
    /// after a reconnect so the resumed session keeps the mirror's grid instead of
    /// reverting to ssh's default 80×24.
    var lastClientSize: (columns: Int, rows: Int)?
    /// The last size ANY writer requested via ``setClientSize(columns:rows:)`` —
    /// the shared dedup baseline for every sizing writer on this connection. A
    /// writer must never dedup against a private cache of what IT last pushed:
    /// the client size is shared session state, and after another writer moves
    /// it, a stale private cache swallows exactly the re-push that would
    /// reconcile the window (the mismatch then persists with no recovery path).
    var lastRequestedClientSize: (columns: Int, rows: Int)? { lastClientSize }
    /// Instant of the most recent sizing write on this connection — kept for
    /// diagnostics (how stale is the last size request).
    var lastSizingSendAt: ContinuousClock.Instant?
    var pendingPostAttachAction: PostAttachAction?

    /// Trailing-edge debounce for `refresh-client -C`. SwiftUI layout settle makes the
    /// rendered grid oscillate (e.g. cols 154→155→156→161→…, ~15 distinct grids in
    /// ~1.3s), and each previously sent its own `refresh-client -C` → ~15 SIGWINCH /
    /// redraw storms on the remote per attach. We now coalesce them: ``setClientSize``
    /// stores the size immediately but defers the send to one shot after the size
    /// stops changing. The fired timer is also the clean "size settled" edge that
    /// consumes the one-shot attach redraw kick below.
    ///
    /// This timer is a rate limiter, not a correctness dependency: the
    /// ledger (`lastClientSize` / `lastWindowSizes`) is written synchronously
    /// before any deferral, dedup makes a late or duplicate send idempotent,
    /// and the reconnect reseed replays the ledger. Reply-gated coalescing is
    /// not a substitute: it self-clocks to the control channel's round trip
    /// (milliseconds locally), which would forward nearly every oscillation
    /// frame and reinstate the SIGWINCH storm — the oscillation has no
    /// terminating event to gate on.
    var clientSizeDebounceTask: Task<Void, Never>?
    static let clientSizeDebounceMs = 180

    /// Armed on every transition to `.connected` (first connect AND reconnect) and
    /// consumed by the first size apply that follows; see
    /// ``scheduleAttachRedrawKickIfNeeded()`` for why attach needs a redraw kick.
    var pendingAttachRedrawKick = false
    var attachRedrawKickTask: Task<Void, Never>?
    /// Gap between the kick's shrink push and its restore push. Must exceed tmux's
    /// pane-resize coalescing (~250 ms), otherwise the two pushes collapse into a
    /// net-zero size change and no SIGWINCH is ever delivered.
    ///
    /// This wait has no event-driven substitute: layout recomputation is
    /// visible to control clients (%layout-change, list-panes) and happens
    /// immediately, but the pane PTY ioctl — the SIGWINCH this kick exists
    /// to force — sits behind tmux's internal coalescing timer, which emits
    /// nothing observable when it expires. Gating the restore on a layout
    /// publication confirms the wrong fact and can land inside the
    /// coalescing window on fast links, collapsing the pair to net-zero
    /// again — and any per-window confirmation predicate can be satisfied
    /// spuriously by an unrelated window already at the shrunken height.
    /// Full evidence + a by-hand exploration: docs/remote-tmux-sizing-timers.md.
    static let attachRedrawKickGapMs = 350

    /// Base reconnect backoff (seconds); doubled each attempt up to ``reconnectMaxDelaySeconds``.
    private static let reconnectBaseDelaySeconds: Double = 1
    /// Cap on the reconnect backoff (seconds). Retries continue indefinitely at this
    /// interval until the network returns or the session is found to be gone.
    private static let reconnectMaxDelaySeconds: Double = 10
    /// Cap on captured stderr (bytes) so a noisy/hostile remote can't grow it unbounded.
    private static let maxStderrBytes = 8 * 1024
    /// Cap queued stdin bytes while the dedicated writer is backpressured. Above
    /// this, mutations are rejected and the connection reconnects instead of
    /// accepting unbounded user input that may never reach tmux.
    private static let maxPendingStdinBytes = 256 * 1024
    /// Cap pending stdout between SSH's pipe callback and the main-actor parser.
    /// Initial attach can legitimately burst one `capture-pane -S 5000` block per
    /// mirrored pane, so the chunk cap absorbs pipe delivery jitter while the byte
    /// cap keeps worst-case memory bounded if parsing falls behind or the remote
    /// floods output. Parser byte budgets remain the control-stream corruption guard.
    private static let maxPendingStdoutBytes = 32 * 1024 * 1024
    private static let maxPendingStdoutChunks = 4096

    /// Subscription-name prefix for per-pane `pane_current_path` (`refresh-client -B`).
    /// The tmux pane id is appended so an inbound `%subscription-changed` can be
    /// routed back to its pane; defined once so the writer and reader can't drift.
    static let cwdSubscriptionPrefix = "cmux_cwd_"

    /// Subscription-name prefix for per-pane reflow classification
    /// (`refresh-client -B`). The subscribed format is
    /// `#{alternate_on}<sep>#{pane_current_command}`; tmux emits it on subscribe
    /// and on every change, so launching/exiting an app (bash → node when claude
    /// starts) re-classifies the pane live. The tmux pane id is appended for
    /// routing, mirroring ``cwdSubscriptionPrefix``.
    static let reflowSubscriptionPrefix = "cmux_reflow_"
    /// Per-pane subscription that keeps header labels LIVE, mirroring
    /// ``cwdSubscriptionPrefix``: tmux pushes the newly-expanded
    /// `pane-border-format` whenever its value changes (a program retitling
    /// its pane, the running command changing) — the same moments native
    /// tmux redraws its own header row.
    static let headerSubscriptionPrefix = "cmux_hdr_"

    /// `ESC[?1049h` — enter the alternate screen, emitted to a mirror surface when
    /// the remote pane is on the alternate screen (see ``capturePane(paneId:)``).
    private static let altScreenEnterSequence = Data("\u{1b}[?1049h".utf8)
    private static let altScreenExitSequence = Data("\u{1b}[?1049l".utf8)

    /// How many lines of pane history `capture-pane` seeds onto a freshly mounted
    /// (or reconnected) mirror surface. Capturing scrollback — not just the visible
    /// screen — is what makes the mirrored tab scrollable from the start; without it
    /// a fresh attach has only the current screen and nothing to scroll up into.
    /// Clamped by the remote pane's `history-limit`, so short panes seed less.
    private static let scrollbackCaptureLines = 5_000

    init(host: RemoteTmuxHost, sessionName: String, createIfMissing: Bool = false) {
        self.host = host
        self.sessionName = sessionName
        self.createIfMissing = createIfMissing
    }

    // MARK: - Observers

    /// Registers a consumer's callbacks and returns a token to deregister them.
    ///
    /// Multiple consumers (e.g. a mirrored workspace and a single-pane display
    /// tab) can observe the same shared connection concurrently; every callback
    /// fires for every event. Pass the returned token to ``removeObserver(_:)``
    /// when the consumer goes away.
    ///
    /// - Parameters:
    ///   - onPaneOutput: receives every `%output` (raw, octal-unescaped bytes).
    ///   - onPaneCwd: receives a pane's working directory (`pane_current_path`),
    ///     both the initial value and live changes (see ``requestPanePath(paneId:)``
    ///     and ``subscribePanePath(paneId:)``).
    ///   - onPaneReflow: receives a pane's reflow classification (`true` = suppress
    ///     reflow on resize for alt-screen / inline-TUI panes like claude; `false`
    ///     = a plain shell whose primary-screen scrollback may reflow), both the
    ///     initial value and live changes (see ``subscribePaneReflow(paneId:)``).
    ///   - onActivePaneChanged: fires when a window's active pane changes
    ///     (`%window-pane-changed`), so consumers can re-project per-pane state
    ///     (e.g. the active pane's directory) onto the window's tab.
    ///   - onSessionChanged: fires when tmux confirms a session name change via
    ///     `%session-changed` or `%session-renamed`.
    ///   - onTopologyChanged: fires when the window/pane topology changes.
    ///   - onExit: fires once when the connection PERMANENTLY ends (a genuine tmux
    ///     `%exit`, or a session found gone on reconnect). A transient transport loss
    ///     does NOT fire this — the connection reconnects instead.
    ///   - onConnectionStateChanged: fires on every ``ConnectionState`` transition
    ///     (e.g. `.connected` → `.reconnecting` on a transport loss), so consumers
    ///     can show a disconnected/reconnecting indicator without tearing down.
    @discardableResult
    func addObserver(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)? = nil,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)? = nil,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)? = nil,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)? = nil,
        onTopologyChanged: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onConnectionStateChanged: ((ConnectionState) -> Void)? = nil
    ) -> ObserverToken {
        observers.add(
            onPaneOutput: onPaneOutput,
            onPaneCwd: onPaneCwd,
            onPaneReflow: onPaneReflow,
            onActivePaneChanged: onActivePaneChanged,
            onSessionChanged: onSessionChanged,
            onTopologyChanged: onTopologyChanged,
            onExit: onExit,
            onConnectionStateChanged: onConnectionStateChanged
        )
    }

    /// Deregisters the callbacks registered under `token`.
    func removeObserver(_ token: ObserverToken) {
        observers.remove(token)
    }

    /// Spawns the SSH `tmux -CC` process and begins streaming.
    func start() throws {
        guard !started else { return }
        try host.ensureControlSocketDirectory()
        // The initial connect honors `createIfMissing`; reconnects never create.
        try spawnProcess(createIfMissing: createIfMissing)
        started = true
    }

    /// Suspends until the control stream really enters tmux control mode, or until
    /// the connection reaches a permanent end. Launch success alone is not enough:
    /// `ssh` can start and then fail authentication/session attach before tmux emits
    /// `%enter`.
    func waitUntilConnected() async -> Bool {
        switch connectionState {
        case .connected:
            return true
        case .ended:
            return false
        case .connecting, .reconnecting:
            break
        }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch connectionState {
                case .connected:
                    continuation.resume(returning: true)
                    return
                case .ended:
                    continuation.resume(returning: false)
                    return
                case .connecting, .reconnecting:
                    break
                }

                connectionWaiters[token] = { connected in
                    continuation.resume(returning: connected)
                }

                if Task.isCancelled {
                    finishConnectionWaiter(token, connected: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishConnectionWaiter(token, connected: false)
            }
        }
    }

    /// Spawns (or re-spawns, on reconnect) the SSH `tmux -CC` process and wires its
    /// stdout into the parser, consuming stderr for session-gone classification.
    /// Resets the per-process state (parser, pending-command FIFO, captured stderr,
    /// `enterReceived`) so a reconnect starts from a clean control stream.
    ///
    /// - Parameter createIfMissing: `true` only for the initial connect. Reconnect
    ///   attempts pass `false` (`attach-session`), so a session killed during the
    ///   outage fails the re-attach (→ `.ended`) instead of being silently recreated.
    private func spawnProcess(createIfMissing: Bool) throws {
        // Fresh control stream: the prior attempt's parser buffer and pending-command
        // FIFO are stale and must not bleed into the new %begin/%end correlation.
        parser = RemoteTmuxControlStreamParser()
        pendingCommands.removeAll()
        pendingLayouts.removeAll()
        initialBatchAwaiting = nil
        initialBatchStaged.removeAll()
        // Normally already flushed by beginReconnecting; kept here so a future
        // caller of spawnProcess can't strand a close decision.
        failPendingActivityQueries()
        attachBlockDrained = false
        stderrBuffer = ""
        enterReceived = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: RemoteTmuxHost.defaultSSHExecutablePath())
        proc.arguments = host.controlModeArguments(
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let stdinWriter = RemoteTmuxControlPipeWriter(
            handle: inPipe.fileHandleForWriting,
            label: "com.cmux.remote-tmux.stdin.\(UUID().uuidString)",
            maxPendingBytes: Self.maxPendingStdinBytes,
            onFailure: { [weak self] in
                self?.handleStdinWriteFailure()
            }
        )

        let stdoutPipeReader = RemoteTmuxStdoutPipeReader(
            maxPendingChunks: Self.maxPendingStdoutChunks,
            maxPendingBytes: Self.maxPendingStdoutBytes,
            onOverflow: { [weak self] in
                self?.handleStdoutBackpressureOverflow()
            }
        )
        let reader = outPipe.fileHandleForReading
        stdoutPipeReader.attach(to: reader)
        // Capture stderr via its own AsyncStream so a failed reconnect attempt can be
        // classified deterministically: `handleStreamEnd` awaits `stderrTask` (which
        // finishes on stderr EOF) before reading `stderrBuffer`, so the decision can't
        // race a not-yet-delivered chunk.
        let (errStream, errContinuation) = AsyncStream<Data>.makeStream()
        let errReader = errPipe.fileHandleForReading
        errReader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errContinuation.finish()
            } else {
                errContinuation.yield(chunk)
            }
        }
        // Finish BOTH streams on process exit so the consumers (and any awaiter)
        // always complete even if a reader's EOF callback is delayed.
        proc.terminationHandler = { _ in
            stdoutPipeReader.close()
            errContinuation.finish()
        }

        do {
            try proc.run()
        } catch {
            // Don't latch `started` on a failed launch, so a later attach can
            // replace this connection instead of reusing a dead one. Close the
            // stdin writer too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            errReader.readabilityHandler = nil
            stdoutPipeReader.close()
            errContinuation.finish()
            stdinWriter.close()
            throw error
        }
        process = proc
        self.stdinWriter = stdinWriter
        stdoutReader = reader
        stderrReader = errReader
        self.stdoutPipeReader = stdoutPipeReader
        stderrContinuation = errContinuation
        stderrTask = Task { [weak self] in
            for await chunk in errStream {
                guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { continue }
                self?.appendStderr(text)
            }
        }
        ingestTask = Task { [weak self] in
            for await chunk in stdoutPipeReader.stream {
                self?.ingest(chunk)
                stdoutPipeReader.release(chunk)
            }
            await self?.handleStreamEnd()
        }
    }

    /// Appends captured stderr, bounded (by UTF-8 bytes) so a noisy/hostile remote
    /// can't grow it without limit. Keeps the tail (the most recent, where the
    /// failure reason is).
    private func appendStderr(_ text: String) {
        stderrBuffer += text
        if stderrBuffer.utf8.count > Self.maxStderrBytes {
            stderrBuffer = String(decoding: Array(stderrBuffer.utf8.suffix(Self.maxStderrBytes)), as: UTF8.self)
        }
    }

    /// Sends a tmux command on the control stream (newline-terminated).
    @discardableResult
    func send(_ command: String) -> Bool {
        sendInternal(command, kind: .other)
    }

    /// The last size any writer requested per window — per-window dedup
    /// baseline and the reconnect re-pin table.
    var lastWindowSizes: [Int: (Int, Int)] = [:]
    /// The most recent window a size was requested for — the deterministic
    /// choice when the old-server fallback must replay ONE size session-wide
    /// (the latest requester is in practice the visible tab).
    var lastSizeRequestWindowId: Int?
    var windowSizeDebounceTasks: [Int: Task<Void, Never>] = [:]
    /// Whether the server accepts `refresh-client -C '@id:WxH'`. Flipped to
    /// false on the first `%error` for that form (older tmux); sizing then
    /// degrades to the session-wide client size.
    var supportsPerWindowSize = true

    /// Requests the current window list + layouts (used to (re)build topology).
    ///
    /// `#{window_name}` is placed last because it can contain spaces, while the
    /// id and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func requestWindows() {
        sendInternal(
            "list-windows -F \"#{window_id} #{window_layout} #{window_visible_layout} [#{window_flags}] #{window_name}\"",
            kind: .listWindows
        )
    }

    /// Fetches one window's REAL pane rectangles (plus the active flag, the
    /// window's `pane-border-status`, and the pane's EXPANDED
    /// `pane-border-format` — exactly the header text a native tmux client
    /// would draw, custom formats included). The layout string is not ground
    /// truth: under `pane-border-status` tmux publishes the pre-title tree
    /// while the displayed panes sit one row lower and shorter — placement
    /// must render where the panes actually are, so a quarantined layout is
    /// published only by this fetch's reply. The expanded format is LAST (it
    /// may contain spaces) behind a `:` sentinel (it may expand to EMPTY,
    /// and a trailing empty field must survive line splitting).
    @discardableResult
    func requestPaneRects(windowId: Int, generation: Int) -> Bool {
        sendInternal(
            "list-panes -t @\(windowId) -F \"#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active} #{pane-border-status} :#{T:pane-border-format}\"",
            kind: .paneRects(windowId, generation)
        )
    }

    /// Rearranges the tracked window order to reflect a just-applied reorder.
    /// `reordered` is the new sequence of a subset of windows (the ones the user
    /// dragged); windows not in it keep their slots. This is synchronous and exact
    /// — the `swap-window` commands achieve precisely this order, so it matches
    /// tmux without a round-trip, and a rapid follow-up reorder reads the
    /// just-applied order rather than a stale one. (A `list-windows` re-fetch would
    /// reintroduce the race: an earlier reorder's async snapshot could land after a
    /// later reorder and roll the order back. Out-of-band changes still reconcile
    /// via the topology events that already trigger ``requestWindows()``.)
    func applyWindowReorder(_ reordered: [Int]) {
        windowOrder = decoding.windowOrder(windowOrder, applyingReorder: reordered)
    }

    /// Captures a pane's current visible contents (with escapes) and delivers
    /// them to the pane-output observers so a freshly-mounted display surface shows
    /// the existing screen instead of starting blank.
    ///
    /// First queries `#{alternate_on}` and, if the remote pane is on the alternate
    /// screen, enters it on the mirror surface (emits `ESC[?1049h`) before the
    /// captured rows so they land on the matching screen and resize behaves like the
    /// remote (the alternate screen does not reflow).
    ///
    /// After the paint it restores terminal state the live `%output` doesn't carry
    /// (it set before cmux attached): scroll region, DEC private modes, the mouse
    /// tracking mode, and the cursor. Restoring the mouse mode means clicks, scroll,
    /// and drag in the mirror are forwarded to the remote app — so drag-to-select
    /// becomes the app's own selection/OSC 52 copy, and **Shift+drag** does a native
    /// cmux copy (exactly as a local terminal behaves with a mouse-mode app).
    func capturePane(paneId: Int) {
        // Match the remote pane's screen (primary vs alternate) BEFORE seeding the
        // captured rows. An alt-screen TUI (e.g. claude) must render on the mirror's
        // alternate screen so resize matches the remote (the alternate screen does
        // not reflow; the primary screen reflows/scrolls and offsets rows). The
        // pane was already on the alt screen before cmux attached, so its 1049h is
        // not in the live %output — query `#{alternate_on}` and enter alt ourselves.
        // Ordered first so the enter lands before the capture paint in the FIFO.
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{alternate_on}\"",
            kind: .paneAltScreen(paneId)
        )
        // `-S -<N>` seeds scrollback history (not just the visible screen) so the
        // mirrored tab is scrollable immediately on attach/reconnect. On an
        // alternate-screen pane there is no history, so tmux clamps to the visible
        // alt screen — harmless.
        //
        // NOTE: do NOT add `-J` (join wrapped lines) here. It was tried to make a
        // shell pane's PRE-ATTACH scrollback rejoin cleanly on grow, but it rewrites
        // an inline/alt-screen TUI's captured rows into different logical lines, so
        // the seed paints shifted on reattach (claude's input line lands a row off
        // and the frame doubles) and scatters on resize. The reflow win for shells
        // comes from LIVE %output (which already carries real soft-wraps), not from
        // the seed — so `-J`'s only upside (pre-attach rejoin-on-grow) isn't worth
        // corrupting every TUI seed. Capture faithful visual rows instead.
        sendInternal("capture-pane -p -e -S -\(Self.scrollbackCaptureLines) -t %\(paneId)", kind: .capturePane(paneId))
        // Query the pane's terminal STATE; tmux exposes it all as formats. Sent
        // after capture-pane so it applies on top of the painted rows (the seed
        // escapes are built in `paneStateSeedSequence`). See the doc comment for why
        // restoring this matters.
        sendInternal(
            "display-message -p -t %\(paneId) -F \""
                + "cursor_x=#{cursor_x},cursor_y=#{cursor_y},"
                + "scroll_region_upper=#{scroll_region_upper},scroll_region_lower=#{scroll_region_lower},"
                + "cursor_flag=#{cursor_flag},insert_flag=#{insert_flag},"
                + "keypad_cursor_flag=#{keypad_cursor_flag},keypad_flag=#{keypad_flag},"
                + "wrap_flag=#{wrap_flag},origin_flag=#{origin_flag},pane_height=#{pane_height},"
                + "mouse_all_flag=#{mouse_all_flag},mouse_button_flag=#{mouse_button_flag},"
                + "mouse_standard_flag=#{mouse_standard_flag},"
                + "mouse_sgr_flag=#{mouse_sgr_flag},mouse_utf8_flag=#{mouse_utf8_flag}\"",
            kind: .paneState(paneId)
        )
    }

    /// Seeds (or re-seeds) a mirrored pane in the one canonical sequence: reflow
    /// classification FIRST (the one-shot query — always works — then the live
    /// subscription for re-classification, e.g. bash → node), then the content
    /// capture, then cwd tracking (initial value + live `cd`). Classification is
    /// queued before the (3-command) capture because it only matters at the next
    /// resize — the earlier it lands, the smaller the window in which a resize
    /// hits the conservative no-reflow default on a slow link.
    func seedPane(paneId: Int) {
        requestPaneReflow(paneId: paneId)
        subscribePaneReflow(paneId: paneId)
        capturePane(paneId: paneId)
        requestPanePath(paneId: paneId)
        subscribePanePath(paneId: paneId)
        subscribePaneHeader(paneId: paneId)
    }

    /// Subscribes to live changes of `paneId`'s expanded `pane-border-format`
    /// (see ``headerSubscriptionPrefix``). The pane-rects fetch seeds the
    /// initial label; this keeps it current between layout events. Quoting is
    /// load-bearing — see ``panePathSubscriptionCommand(paneId:)``.
    func subscribePaneHeader(paneId: Int) {
        send("refresh-client -B \"\(Self.headerSubscriptionPrefix)\(paneId):%\(paneId):#{T:pane-border-format}\"")
    }

    func unsubscribePaneHeader(paneId: Int) {
        send("refresh-client -B \(Self.headerSubscriptionPrefix)\(paneId)")
    }

    /// Format for close-time activity queries: the pane id (for cache refresh and
    /// multi-pane correlation) plus the same `alternate_on`/`pane_current_command`
    /// pair the reflow subscription streams. Quoted by the command builders — see
    /// ``panePathSubscriptionCommand(paneId:)`` for why the quoting is load-bearing.
    static let activityQueryFormat = "#{pane_id}\(PaneForegroundState.fieldSeparator)"
        + "#{alternate_on}\(PaneForegroundState.fieldSeparator)#{pane_current_command}"

    private func finishConnectionWaiters(connected: Bool) {
        guard !connectionWaiters.isEmpty else { return }
        let waiters = Array(connectionWaiters.values)
        connectionWaiters.removeAll()
        for waiter in waiters {
            waiter(connected)
        }
    }

    private func finishConnectionWaiter(_ token: UUID, connected: Bool) {
        connectionWaiters.removeValue(forKey: token)?(connected)
    }

    /// Sends literal key bytes to a pane via tmux `send-keys -H` (hex-encoded),
    /// which is binary-safe and needs no shell quoting.
    @discardableResult
    func sendKeys(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        let hex = Self.hexByteArguments(data)
        return sendInternal("send-keys -t %\(paneId) -H \(hex)", kind: .other)
    }

    nonisolated static func hexByteArguments(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 3 - 1)
        for byte in data {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: " ")) }
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Pastes `text` into `paneId` as a tmux paste (`paste-buffer -p`), which wraps
    /// the content in bracketed-paste markers IFF the real pane's app has
    /// bracketed-paste mode enabled — tmux tracks that on the real pty, which the
    /// mirror surface can't see. This makes a pasted/dropped image path arrive as a
    /// genuine paste, so the remote app recognizes it (e.g. claude → `[Image #N]`)
    /// instead of seeing the plain keystrokes that ``sendKeys(paneId:data:)`` would
    /// deliver. Uses a dedicated, immediately-deleted (`-d`) per-pane buffer so
    /// there's no buffer-name collision. `text` must be a single line (callers route
    /// only single-line content — e.g. file/image paths — here).
    func pastePane(paneId: Int, text: String) -> Bool {
        guard let commands = Self.pastePaneCommands(paneId: paneId, text: text) else { return false }
        return send(commands.setBuffer) && send(commands.pasteBuffer)
    }

    nonisolated static func pastePaneCommands(paneId: Int, text: String)
        -> (setBuffer: String, pasteBuffer: String)?
    {
        guard !text.isEmpty else { return nil }
        let buffer = "cmux-paste-\(paneId)"
        return (
            setBuffer: "set-buffer -b \(buffer) -- \(RemoteTmuxHost.shellSingleQuoted(text))",
            pasteBuffer: "paste-buffer -p -d -b \(buffer) -t %\(paneId)"
        )
    }

    /// Detaches: terminating ssh kills the control client but leaves the remote
    /// tmux session alive for resume. Permanently ends the connection — no reconnect.
    func stop() {
        // Mark `.ended` FIRST so the deliberate teardown's stream-end is ignored and
        // never fires `onExit` or a reconnect: only a genuine remote end (a real
        // `%exit` or a session found gone on reconnect) notifies exit observers — so
        // detach / quit / window-close (preserve) and transport drops do not.
        connectionState = .ended
        cancelScheduledWork()
        teardownProcessHandles()
    }

    /// Cancels every scheduled follow-up (reconnect, debounced size send, redraw
    /// kick) and the deferred post-attach work. Shared by deliberate teardown
    /// (``stop()``) and a genuine remote end (`%exit`).
    private func cancelScheduledWork() {
        failPendingActivityQueries()
        reconnectTask?.cancel()
        reconnectTask = nil
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = nil
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = nil
        pendingAttachRedrawKick = false
        pendingPostAttachAction = nil
    }

    /// Tears down the current spawn's process and I/O handles WITHOUT changing
    /// `connectionState`, so the connection can either end (``stop()``) or re-spawn
    /// (reconnect) from a clean slate.
    private func teardownProcessHandles() {
        ingestTask?.cancel()
        ingestTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminationHandler = nil
        // Tear down the readers deterministically rather than waiting for EOF (the
        // consumers are already cancelled).
        stderrReader?.readabilityHandler = nil
        stderrReader = nil
        stdoutPipeReader?.close()
        stdoutPipeReader = nil
        stdoutReader = nil
        stderrContinuation?.finish()
        stderrContinuation = nil
        stdinWriter?.close()
        stdinWriter = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Internals

    @discardableResult
    func sendInternal(_ command: String, kind: CommandKind) -> Bool {
        guard connectionState == .connected, let stdinWriter else { return false }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        guard let data = line.data(using: .utf8) else { return false }
        // Record before the writer can emit bytes, so a fast `%begin`/`%end`
        // reply never outruns its local FIFO slot. If the bounded writer rejects
        // the command, remove this slot immediately and reconnect.
        pendingCommands.append(kind)
        guard stdinWriter.enqueue(data) else {
            pendingCommands.removeLast()
            record("stdin-write-backpressure")
            beginReconnecting()
            return false
        }
        return true
    }

    private func handleStdinWriteFailure() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        // The control pipe is dead (broken pipe or a closed SSH child). Keep the
        // mirror frozen and reconnect; teardown finishes the old streams so
        // pending command correlation cannot consume replies from a dead client.
        record("stdin-write-failed")
        beginReconnecting()
    }

    private func handleStdoutBackpressureOverflow() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        // The parser fell far enough behind the SSH pipe that preserving every
        // control-mode byte would exceed the bridge budget. Reconnect instead of
        // dropping bytes and desynchronizing command/result parsing.
        record("stdout-backpressure")
        beginReconnecting()
    }

    private func ingest(_ data: Data) {
        for message in parser.feed(data) {
            handle(message)
        }
    }

    private func handleStreamEnd() async {
        record("stream-end")
        switch connectionState {
        case .ended:
            return
        case .connecting, .connected:
            // The control stream died without `%exit` — a transport loss. Keep the
            // mirror frozen and reconnect.
            beginReconnecting()
        case .reconnecting:
            // A reconnect attempt's process exited before reaching control mode
            // (a successful attach would have moved us to `.connected` via `.enter`).
            // Drain the attempt's stderr to completion (the process has exited, so the
            // stream finishes) BEFORE classifying, so the decision can't race a
            // not-yet-delivered chunk and misclassify a gone session as transient.
            await stderrTask?.value
            // A state change may have raced the drain (e.g. a deliberate stop()).
            guard connectionState == .reconnecting else { return }
            // Classify: a session/server found gone is a genuine end; anything else
            // (host unreachable, refused) is transient — keep retrying with backoff.
            let sessionGone = decoding.stderrIndicatesSessionGone(stderrBuffer)
            teardownProcessHandles()
            if sessionGone {
                record("reconnect-session-gone")
                connectionState = .ended
                reconnectTask?.cancel()
                reconnectTask = nil
                observers.notifyExit()
            } else {
                scheduleReconnectAttempt()
            }
        }
    }

    // MARK: - Reconnect

    /// Begins reconnecting after a transport loss: tears down the dead spawn, marks
    /// `.reconnecting` (consumers keep the frozen mirror), and schedules the first
    /// retry. No-op unless currently connected/connecting.
    private func beginReconnecting() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        record("reconnecting")
        // The stream is dead: a close decision awaiting an activity query must
        // not hang for the whole backoff window — fail it onto the cache now.
        failPendingActivityQueries()
        teardownProcessHandles()
        reconnectAttemptCount = 0
        connectionState = .reconnecting
        scheduleReconnectAttempt()
    }

    /// Schedules the next reconnect attempt after a capped exponential backoff.
    private func scheduleReconnectAttempt() {
        let attempt = reconnectAttemptCount
        reconnectAttemptCount += 1
        let delay = min(
            Self.reconnectMaxDelaySeconds,
            Self.reconnectBaseDelaySeconds * pow(2, Double(attempt))
        )
        record("reconnect-scheduled attempt=\(attempt) delay=\(delay)")
        reconnectTask?.cancel()
        // A bounded, cancellable backoff before the next attempt (not a poll/settle):
        // cancelled by stop()/genuine end, re-armed by each failed attempt. `do/catch`
        // (not `try?`) so a cancelled sleep returns immediately — the previously
        // scheduled task can't fall through and double-spawn a second ssh client.
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.connectionState == .reconnecting else { return }
            self.attemptReconnectSpawn()
        }
    }

    /// Re-spawns the ssh control client for a reconnect attempt. Always attach-only
    /// (`createIfMissing: false`) so a session killed during the outage fails the
    /// re-attach (→ classified `.ended`) instead of being silently recreated empty.
    /// A spawn failure (e.g. control-socket dir) backs off and retries; the spawn's
    /// success/failure is observed via `.enter` (connected) or `handleStreamEnd`.
    private func attemptReconnectSpawn() {
        record("reconnect-attempt")
        do {
            try spawnProcess(createIfMissing: false)
        } catch {
            scheduleReconnectAttempt()
        }
    }

    /// Re-seeds every mirrored pane after a successful reconnect: the fresh ssh
    /// client lost the prior screen, cwd subscriptions, and client size, so re-apply
    /// the grid, then per pane clear the stale frozen content (screen + scrollback)
    /// and re-capture current contents (with history) + cwd. Called from the first
    /// post-reconnect `list-windows` result, so `windowsByID` is freshly repopulated
    /// and the command-result FIFO is aligned (the attach block is already drained).
    func reseedAfterReconnect() {
        if let size = lastClientSize {
            send("refresh-client -C \(size.columns)x\(size.rows)")
        }
        // Re-pin every per-window size: pins are per-client state, and the
        // fresh ssh client starts with none (windows would sit at 80×24 or
        // the session-wide size). Feed-forward by nature — replays recorded
        // requests, reads nothing back.
        if supportsPerWindowSize {
            for (windowId, size) in lastWindowSizes.sorted(by: { $0.key < $1.key }) {
                sendPerWindowSize(windowId: windowId, columns: size.0, rows: size.1)
            }
        }
        // The re-applied size is usually a no-op (the server kept the window at our
        // size across the transport drop), so TUIs get no SIGWINCH — kick them so
        // they repaint over the re-seeded (possibly stale) frame. FIFO-safe: the
        // captures below are queued before the kick task's first push can run.
        scheduleAttachRedrawKickIfNeeded()
        for window in windowsByID.values {
            for paneId in window.paneIDsInOrder {
                observers.emitPaneOutput(paneId, Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8))
                seedPane(paneId: paneId)
            }
        }
    }

    private func handle(_ message: RemoteTmuxControlMessage) {
        switch message {
        case .enter:
            enterReceived = true
            record("enter")
            // First connect, or a reconnect attempt that reached control mode.
            if connectionState != .connected {
                let wasReconnecting = connectionState == .reconnecting
                connectionState = .connected
                // Arm the one-shot attach redraw kick: if the upcoming size apply is
                // a no-op (window already at our size), a running TUI gets no SIGWINCH
                // and would keep showing its stale pre-attach frame. Consumed by the
                // first size apply (debounced send, reconnect re-seed, or the
                // first-connect list-windows result).
                pendingAttachRedrawKick = true
                reconnectAttemptCount = 0
                reconnectTask?.cancel()
                reconnectTask = nil
                // Do not send here: `.enter` precedes the attach result block, so a
                // command queued now could be consumed by that result and shift the
                // FIFO. The attach-block drain queues list-windows once alignment is safe.
                pendingPostAttachAction = wasReconnecting ? .reseed : .applyClientSize
            }
        case let .exit(reason):
            record("exit\(reason.map { " " + $0 } ?? "")")
            // A genuine remote end (session/server intentionally exited). No reconnect.
            guard connectionState != .ended else { return }
            connectionState = .ended
            cancelScheduledWork()
            observers.notifyExit()
        case let .output(paneId, data):
            paneOutputByteCounts[paneId, default: 0] += data.count
            totalOutputBytes += data.count
            observers.emitPaneOutput(paneId, data)
        case let .sessionChanged(id, name):
            // An attached-session SWITCH: the window set changes with it, so
            // re-fetch the topology.
            applySessionNameChange(sessionId: id, name: name, event: "session-changed", refetchWindows: true)
        case let .sessionRenamed(id, name, idBearingName):
            // tmux's `rename-session` notification. Same name handling as
            // `%session-changed` (track the new name for attach/reconnect and emit
            // the name-change observers that re-key controller state and re-title
            // the mirror workspace), but a rename does NOT change the window set,
            // so skip the topology re-fetch.
            guard let renameName = sessionRenamedName(
                sessionId: id,
                documentedName: name,
                idBearingName: idBearingName
            ) else { return }
            applySessionNameChange(sessionId: id, name: renameName, event: "session-renamed", refetchWindows: false)
        case .sessionsChanged:
            record("sessions-changed")
        case let .windowAdd(id):
            record("window-add @\(id)")
            requestWindows()
        case let .windowClose(id):
            // Release the closed window's per-window sizing state: a stale
            // entry would be replayed by the reconnect reseed, and a pending
            // debounce could still fire at a dead @id target.
            lastWindowSizes[id] = nil
            windowSizeDebounceTasks[id]?.cancel()
            windowSizeDebounceTasks[id] = nil
            // Release the closed window's per-pane/per-window diagnostic state so
            // it doesn't accumulate across window churn.
            if let closing = windowsByID[id] {
                for pane in closing.paneIDsInOrder {
                    paneOutputByteCounts[pane] = nil
                    paneForegroundStates[pane] = nil
                }
            }
            activePaneByWindow[id] = nil
            windowsByID[id] = nil
            windowTitleRowsVisible[id] = nil
            windowOrder.removeAll { $0 == id }
            pendingLayouts[id] = nil
            initialBatchStaged[id] = nil
            finishInitialBatchMember(id)
            record("window-close @\(id)")
            observers.notifyTopologyChanged()
        case let .windowRenamed(id, name):
            record("window-renamed @\(id)")
            // Propagate the new name into the topology so the mirrored tab title
            // refreshes. Keep the existing geometry/layout — including the
            // visible tree and zoom flag, or renaming a zoomed window would
            // flip its mirror back to the base tree.
            if let existing = windowsByID[id], existing.name != name {
                windowsByID[id] = RemoteTmuxWindow(
                    id: id, name: name,
                    width: existing.width, height: existing.height, layout: existing.layout,
                    visibleLayout: existing.visibleLayout, zoomed: existing.zoomed
                )
                observers.notifyTopologyChanged()
            }
        case let .layoutChange(id, layout, visibleLayout, zoomed):
            // No topology notify here: the layout STRING is not render-ready
            // truth (its pane rects ignore pane-border-status rows), and
            // rendering it briefly before the rects reply lands makes panes
            // visibly bob one row per layout event. `applyLayout` queues the
            // pane-rects fetch, and ITS reply notifies — one round trip, one
            // truthful render.
            applyLayout(windowId: id, layout: layout, visibleLayout: visibleLayout, zoomed: zoomed)
            record("layout-change @\(id)\(zoomed ? " zoomed" : "")")
        case let .windowPaneChanged(windowId, paneId):
            activePaneByWindow[windowId] = paneId
            observers.emitActivePaneChanged(windowId, paneId)
        case let .sessionWindowChanged(_, windowId):
            record("session-window-changed @\(windowId)")
        case let .subscriptionChanged(name, value):
            // cmux subscribes each pane's working directory as "cmux_cwd_<paneId>".
            if name.hasPrefix(Self.cwdSubscriptionPrefix),
               let paneId = Int(name.dropFirst(Self.cwdSubscriptionPrefix.count)) {
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { observers.emitPaneCwd(paneId, path) }
            } else if name.hasPrefix(Self.reflowSubscriptionPrefix),
                      let paneId = Int(name.dropFirst(Self.reflowSubscriptionPrefix.count)) {
                // Reflow classification: "<alternate_on>|<pane_current_command>".
                classifyAndEmitReflow(paneId: paneId, rawValue: value, source: "sub")
            } else if name.hasPrefix(Self.headerSubscriptionPrefix),
                      let paneId = Int(name.dropFirst(Self.headerSubscriptionPrefix.count)) {
                // Live header text: the pane's re-expanded pane-border-format.
                // The topology notify re-runs the mirrors' reconcile, which
                // copies labels — the same path the rects fetch uses.
                let label = Self.strippingStyleTokens(value)
                if paneHeaderLabels[paneId] != label {
                    paneHeaderLabels[paneId] = label
                    observers.notifyTopologyChanged()
                }
            }
        case let .commandResult(_, lines, isError):
            // The first block on each control stream is the attach command's own —
            // consume it explicitly so it can never pop a queued command's slot off
            // the positional FIFO (see ``attachBlockDrained``).
            if !attachBlockDrained {
                attachBlockDrained = true
                requestWindows()
            } else {
                handleCommandResult(lines: lines, isError: isError)
            }
        case let .streamError(reason):
            record("stream-error \(reason)")
            beginReconnecting()
        case .ignoredNotification, .unparsed:
            break
        }
    }

    /// Shared handling for `%session-changed` and `%session-renamed`: validate the
    /// name, update the tracked `sessionName` (and `sessionId` for session
    /// switches), then emit the name-change observers (which re-key controller
    /// state and re-title the mirror workspace). `sessionName` is reused for
    /// attach/reconnect, so a stale value would make the next reconnect target the
    /// wrong session and wrongly declare it gone.
    ///
    /// - Parameter refetchWindows: re-fetch the window topology afterwards. A
    ///   session SWITCH (`%session-changed`) brings a different window set, so it
    ///   must; a rename (`%session-renamed`) keeps the same windows, so it skips
    ///   the extra round trip. An invalid name always re-fetches as a recovery
    ///   resync regardless.
    private func applySessionNameChange(sessionId newSessionId: Int?, name: String, event: String, refetchWindows: Bool) {
        guard let safeName = RemoteTmuxHost.controlModeLineSafeName(name) else {
            let idSuffix = newSessionId.map { " $\($0)" } ?? ""
            record("\(event)-invalid\(idSuffix)")
            requestWindows()
            return
        }
        let oldName = sessionName
        if let newSessionId { sessionId = newSessionId }
        sessionName = safeName
        let idSuffix = newSessionId.map { " $\($0)" } ?? ""
        record("\(event)\(idSuffix)")
        observers.emitSessionChanged(oldName: oldName, newName: safeName)
        if refetchWindows { requestWindows() }
    }

    private func sessionRenamedName(sessionId renamedSessionId: Int?, documentedName: String, idBearingName: String?) -> String? {
        guard let renamedSessionId else { return documentedName }
        // Real tmux id-bearing renames are broadcast for every session; only this
        // connection's id may use the id-bearing interpretation.
        guard let currentSessionId = sessionId, currentSessionId == renamedSessionId else {
            record("session-renamed-ignored $\(renamedSessionId)")
            return nil
        }
        return idBearingName ?? documentedName
    }

    /// Per-pane header-strip labels: the pane's EXPANDED `pane-border-format`
    /// (style tokens stripped) — exactly the text a native tmux client draws
    /// in that pane's header, custom formats included. Seeded by the
    /// pane-rects fetch and kept LIVE by a per-pane subscription
    /// (`cmux_hdr_<pane>`), so a program retitling its pane updates the strip
    /// the moment tmux would redraw its own border. The mirror copies its
    /// windows' subset on reconcile; the view never reads this directly.
    var paneHeaderLabels: [Int: String] = [:]

    /// Whether each window currently has `pane-border-status top` — i.e.
    /// tmux itself is drawing header rows, which is the ONLY time the strips
    /// show label text (a stock tmux displays no titles anywhere; cmux adds
    /// only the active-pane dot on top of that).
    var windowTitleRowsVisible: [Int: Bool] = [:]

    /// Drops tmux `#[...]` style tokens from an expanded format (tmux marks
    /// the active pane by reversing its index; the dot carries that signal
    /// here).
    static func strippingStyleTokens(_ value: String) -> String {
        value.replacingOccurrences(
            of: "#\\[[^\\]]*\\]", with: "", options: .regularExpression
        )
    }

    /// A layout the module has PARSED but not yet PUBLISHED: the layout
    /// string's leaf rects are wrong under `pane-border-status` (tmux
    /// publishes the pre-title tree), so raw trees are quarantined here and
    /// enter `windowsByID` only patched with list-panes rects — observers
    /// can never see string geometry, structurally.
    struct PendingLayout {
        var node: RemoteTmuxLayoutNode
        var visibleNode: RemoteTmuxLayoutNode?
        var zoomed: Bool
        var name: String
        /// Bumped per stored layout; a rects reply for an older generation
        /// is stale and discarded (a fresh fetch is already in flight or
        /// queued via `dirty`).
        var generation: Int
        /// A newer layout arrived while a rects fetch was in flight: send
        /// ONE follow-up fetch when the in-flight reply lands (coalescing —
        /// a resize storm must not queue a fetch per event).
        var dirty = false
        var inFlight = false
        var retriesRemaining = 1
    }
    var pendingLayouts: [Int: PendingLayout] = [:]

    /// Window ids from a topology population that started with NO published
    /// windows (first attach, reconnect reseed into an empty table), still
    /// awaiting their rects reply. While non-nil, verified windows accumulate
    /// in `initialBatchStaged` and flush to `windowsByID` in ONE atomic
    /// publish when the set drains. Without the barrier, each window would
    /// publish in rects-reply arrival order, and the mirror layer's tab
    /// creation order — and with it which tab ends up selected and which
    /// mirrors take their one-time size claim from a hidden, collapsed
    /// container — would be a race between round trips.
    var initialBatchAwaiting: Set<Int>?
    var initialBatchStaged: [Int: RemoteTmuxWindow] = [:]

    func record(_ event: String) {
        diagnostics.record(event)
    }

    /// An immutable, `Sendable` snapshot for diagnostics (`remote.tmux.state`).
    func snapshot() -> Snapshot {
        Snapshot(
            started: started,
            enterReceived: enterReceived,
            exited: exited,
            sessionId: sessionId,
            windowCount: windowsByID.count,
            windowIDs: windowOrder,
            paneOutputByteCounts: paneOutputByteCounts,
            totalOutputBytes: totalOutputBytes,
            recentEvents: diagnostics.events
        )
    }

    #if DEBUG
    func installStdinWriterForTesting(_ writer: RemoteTmuxControlPipeWriter) { stdinWriter = writer }
    func handleMessageForTesting(_ message: RemoteTmuxControlMessage) { handle(message) }
    var pendingCommandKindsForTesting: [RemoteTmuxControlCommandKind] { pendingCommands }
    #endif

}
