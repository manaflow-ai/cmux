import CmuxRemoteSession
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
    /// The host this connection talks to.
    let host: RemoteTmuxHost
    /// The tmux session name this connection attaches to. Mutable because a
    /// `rename-session` changes it (the underlying `$id` is stable).
    private(set) var sessionName: String

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

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
    private(set) var sessionId: Int?
    var windowsByID: [Int: RemoteTmuxWindow] = [:]
    var windowOrder: [Int] = []
    var publishedWindowIdByPane: [Int: Int] = [:]
    /// Pane identities whose ownership is temporarily undecidable after their
    /// source window closes, retained until `list-windows` supplies a complete snapshot.
    var paneIDsRetainedUntilWindowList: Set<Int> = []
    var activePaneByWindow: [Int: Int] = [:]
    var paneOutputByteCounts: [Int: Int] = [:]
    var totalOutputBytes = 0
    /// Per-pane header-strip labels: the pane's EXPANDED `pane-border-format`
    /// (style tokens stripped) — exactly the text a native tmux client draws
    /// in that pane's header, custom formats included. Seeded by the
    /// pane-rects fetch and kept LIVE by a per-pane subscription
    /// (`cmux_hdr_<pane>`), so a program retitling its pane updates the strip
    /// the moment tmux would redraw its own border. The mirror copies its
    /// windows' subset on reconcile; the view never reads this directly.
    var paneHeaderLabels: [Int: String] = [:]
    /// Configured tmux pane-title placement per window; absence means off.
    var windowTitleRowPlacements: [Int: RemoteTmuxPaneTitleRowPlacement] = [:]
    /// Layouts awaiting authoritative pane rectangles before publication.
    var pendingLayouts: [Int: RemoteTmuxPendingLayout] = [:]
    /// Window ids in the initial atomic topology publication batch.
    var initialBatchAwaiting: Set<Int>?
    /// Verified initial windows staged until the atomic batch is complete.
    var initialBatchStaged: [Int: RemoteTmuxWindow] = [:]
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
    var newWindowCompletions: [UUID: (Int?) -> Void] = [:]
    /// Completions for ``sendTracked(_:completion:)`` blocks, keyed by the
    /// `.tracked` token in the FIFO. Guaranteed exactly one edge each: `%end`,
    /// `%error`, or a stream reset (``failPendingTrackedSends()``) — callers
    /// build protocol-anchored state machines on that guarantee.
    var trackedSendCompletions: [UUID: (Bool) -> Void] = [:]

    private var process: Process?
    var stdinWriter: RemoteTmuxControlPipeWriter?
    private var stdoutReader: FileHandle?
    private var stdoutPipeReader: RemoteTmuxProcessOutputReader?
    private var stderrPipeReader: RemoteTmuxProcessOutputReader?
    /// Consumes the current spawn's stderr into `stderrBuffer`. Awaited before a
    /// failed reconnect attempt is classified, so the decision sees the complete
    /// error rather than racing the async stderr delivery.
    private var stderrTask: Task<Void, Never>?
    private var parser = RemoteTmuxControlStreamParser()
    private var ingestTask: Task<Void, Never>?
    private var processGeneration: UInt64 = 0
    var pendingCommands: [CommandKind] = []
    var windowListRequestInFlight = false
    var windowListRequestDirty = false
    var windowReorderBatchFailed = false
    var windowReorderGeneration: UInt64 = 0
    var windowReorderRecoveryGeneration: UInt64?
    var windowReorderVerificationGeneration: UInt64?
    var windowReorderVerifications: [UInt64: (Bool) -> Void] = [:]
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
    let diagnostics = RemoteTmuxConnectionDiagnostics()

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
    private var preControlOutputBuffer = ""
    /// Last client size applied via ``setClientSize(columns:rows:)``, re-applied
    /// after a reconnect so the resumed session keeps the mirror's grid instead of
    /// reverting to ssh's default 80×24.
    var lastClientSize: (columns: Int, rows: Int)?
    /// The last size any writer requested per window — per-window dedup
    /// baseline and the reconnect re-pin table.
    var lastWindowSizes: [Int: (Int, Int)] = [:]
    var maximumWindowClaimColumns = 0
    var maximumWindowClaimRows = 0
    /// What the SERVER has actually been sent, per window — the dedup
    /// baseline. Distinct from ``lastWindowSizes`` (what callers requested):
    /// a request made while the connection is attaching is recorded but not
    /// sent, and deduping against the request table then suppressed every
    /// retry of a size the server never saw — a claim wedged at attach
    /// stayed wedged for the connection's lifetime.
    var sentWindowSizes: [Int: (Int, Int)] = [:]
    /// Re-arms spent against a window whose %layout-change size keeps
    /// disagreeing with a claim the sent ledger says was delivered. Reset
    /// on agreement and on a new claim value; see
    /// ``reassertWindowClaimIfLayoutDisagrees(windowId:layoutColumns:layoutRows:)``.
    var windowClaimParityRearmsSpent: [Int: Int] = [:]
    /// The most recent window a size was requested for — the deterministic
    /// choice when the old-server fallback must replay one size session-wide.
    var lastSizeRequestWindowId: Int?
    var windowSizeDebounceTasks: [Int: Task<Void, Never>] = [:]
    /// Whether the server accepts per-window `refresh-client -C` sizing.
    var supportsPerWindowSize = true
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
    /// Per-window mid-session redraw kicks, keyed by window id. Each window
    /// owns its own shrink→restore task so a second window's kick cannot
    /// cancel the first window's restore and strand it at the shrunk size.
    var perWindowRedrawKickTasks: [Int: Task<Void, Never>] = [:]
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
    private static let maxPendingStderrBytes = 1024 * 1024
    private static let maxPendingStderrChunks = 256

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

    /// Per-WINDOW subscription to `pane-border-status`, the one layout input tmux
    /// changes with no notification of its own.
    ///
    /// Turning the option on or off resizes and moves every pane touching the
    /// configured edge (measured on tmux 3.7: a 12-row pane at top 0 becomes an
    /// 11-row pane at top 1) while the window's LAYOUT STRING is unchanged — the
    /// string does not encode the title row — so tmux emits no `%layout-change`.
    /// Pane heights come from the rects fetch that a `%layout-change` drives, so
    /// without this subscription the published tree keeps the pre-toggle heights
    /// until some unrelated layout event happens to refresh it, and every
    /// edge-touching pane renders a row off from what tmux actually holds.
    /// tmux pushes the value once on subscribe and again on every change, for
    /// hidden windows as well as the current one (both verified on 3.7), so the
    /// mirror learns the change on an event instead of polling for it.
    static let borderStatusSubscriptionPrefix = "cmux_border_"

    /// The last `pane-border-status` value each window's subscription reported.
    /// The initial push needs no refetch (the attach's own rects fetch is already
    /// current); only a CHANGE means the published heights went stale.
    var borderStatusByWindow: [Int: String] = [:]

    /// Windows whose `pane-border-status` subscription this client has issued.
    /// Subscriptions belong to the CLIENT, so a reconnect drops them all and the
    /// reseed's restage must issue them again (see ``reseedAfterReconnect()``).
    var borderStatusSubscribedWindows: Set<Int> = []

    /// `ESC[?1049h` — enter the alternate screen, emitted to a mirror surface when
    /// the remote pane is on the alternate screen (see ``capturePane(paneId:)``).
    static let altScreenEnterSequence = Data("\u{1b}[?1049h".utf8)
    static let altScreenExitSequence = Data("\u{1b}[?1049l".utf8)

    init(host: RemoteTmuxHost, sessionName: String, createIfMissing: Bool = false) {
        self.host = host
        self.sessionName = sessionName
        self.createIfMissing = createIfMissing
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
        // A fresh control stream cannot retain the prior parser or command FIFO.
        #if DEBUG
        cmuxDebugLog("remote.stream.reset pendingCommands=\(pendingCommands.count) createIfMissing=\(createIfMissing)")
        #endif
        parser = RemoteTmuxControlStreamParser()
        pendingCommands.removeAll()
        resetWindowListRequestCoalescing()
        windowReorderBatchFailed = false
        windowReorderRecoveryGeneration = nil
        pendingLayouts.removeAll()
        initialBatchAwaiting = nil
        initialBatchStaged.removeAll()
        // Normally already flushed by beginReconnecting; kept here so a future
        // caller of spawnProcess can't strand command decisions.
        failPendingActivityQueries()
        failPendingNewWindowRequests()
        failPendingWindowReorderVerifications()
        failPendingTrackedSends()
        attachBlockDrained = false
        stderrBuffer = ""
        preControlOutputBuffer = ""
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

        let stdoutPipeReader = RemoteTmuxProcessOutputReader(
            label: "com.cmux.remote-tmux.stdout.\(UUID().uuidString)",
            maxPendingChunks: Self.maxPendingStdoutChunks,
            maxPendingBytes: Self.maxPendingStdoutBytes,
            onOverflow: { [weak self] in
                self?.handleStdoutBackpressureOverflow()
            }
        )
        let reader = outPipe.fileHandleForReading
        stdoutPipeReader.attach(to: reader)
        let stderrPipeReader = RemoteTmuxProcessOutputReader(
            label: "com.cmux.remote-tmux.stderr.\(UUID().uuidString)",
            maxPendingChunks: Self.maxPendingStderrChunks,
            maxPendingBytes: Self.maxPendingStderrBytes,
            onOverflow: { [weak self] in
                self?.handleStderrBackpressureOverflow()
            }
        )
        stderrPipeReader.attach(to: errPipe.fileHandleForReading)
        // Process termination and pipe EOF are distinct events. Each reader drains
        // its descriptor before ending the stream so final `%exit` or stderr bytes
        // cannot be discarded by a faster termination callback.
        proc.terminationHandler = { _ in
            stdoutPipeReader.processDidExit()
            stderrPipeReader.processDidExit()
        }

        do {
            try proc.run()
        } catch {
            // Don't latch `started` on a failed launch, so a later attach can
            // replace this connection instead of reusing a dead one. Close the
            // stdin writer too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            stdoutPipeReader.close()
            stderrPipeReader.close()
            stdinWriter.close()
            throw error
        }
        process = proc
        self.stdinWriter = stdinWriter
        stdoutReader = reader
        self.stdoutPipeReader = stdoutPipeReader
        self.stderrPipeReader = stderrPipeReader
        processGeneration &+= 1
        let generation = processGeneration
        stderrTask = Task { [weak self] in
            for await chunk in stderrPipeReader.stream {
                if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                    self?.appendStderr(text)
                }
                stderrPipeReader.release(chunk)
            }
        }
        ingestTask = Task { [weak self] in
            for await chunk in stdoutPipeReader.stream {
                self?.ingest(chunk)
                stdoutPipeReader.release(chunk)
            }
            guard !Task.isCancelled else { return }
            await self?.handleStreamEnd(processGeneration: generation)
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

    /// Cancels every scheduled follow-up (reconnect, debounced size sends, redraw
    /// kick) and the deferred post-attach work. Shared by deliberate teardown
    /// (``stop()``) and a genuine remote end (`%exit`).
    private func cancelScheduledWork() {
        failPendingActivityQueries()
        failPendingNewWindowRequests()
        failPendingWindowReorderVerifications()
        failPendingTrackedSends()
        reconnectTask?.cancel()
        reconnectTask = nil
        resetWindowListRequestCoalescing()
        cancelSizingFollowUps()
        pendingPostAttachAction = nil
    }

    private func cancelSizingFollowUps() {
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = nil
        for task in windowSizeDebounceTasks.values {
            task.cancel()
        }
        windowSizeDebounceTasks.removeAll()
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = nil
        for task in perWindowRedrawKickTasks.values { task.cancel() }
        perWindowRedrawKickTasks.removeAll()
        pendingAttachRedrawKick = false
    }

    /// Tears down the current spawn's process and I/O handles WITHOUT changing
    /// `connectionState`, so the connection can either end (``stop()``) or re-spawn
    /// (reconnect) from a clean slate.
    private func teardownProcessHandles() {
        processGeneration &+= 1
        ingestTask?.cancel()
        ingestTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminationHandler = nil
        // Tear down the readers deterministically rather than waiting for EOF (the
        // consumers are already cancelled).
        stdoutPipeReader?.close()
        stdoutPipeReader = nil
        stdoutReader = nil
        stderrPipeReader?.close()
        stderrPipeReader = nil
        stdinWriter?.close()
        stdinWriter = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Internals

    @discardableResult
    func sendInternal(_ command: String, kind: CommandKind) -> Bool {
        #if DEBUG
        // Sizing sends were invisible: every claimed-vs-layout wedge was
        // debugged by inference about what tmux was told. Log the exact
        // command so the send side is evidence, not conjecture. `capture-pane`
        // is here for the same reason — it is how a grown pane's late-granted
        // cells get refilled (see repaintPaneVisibleScreen), so "did the repaint
        // fire?" must be answerable from the log rather than argued.
        if command.hasPrefix("refresh-client") || command.hasPrefix("capture-pane") {
            cmuxDebugLog("remote.send state=\(connectionState) \(command)")
        }
        #endif
        return sendBatchInternal([command], kinds: [kind])
    }

    /// Atomically records command-result correlation before enqueueing one payload.
    @discardableResult
    func sendBatchInternal(_ commands: [String], kinds: [CommandKind]) -> Bool {
        guard !commands.isEmpty, commands.count == kinds.count else { return false }
        guard connectionState == .connected, let stdinWriter else { return false }
        let payload = commands.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
        guard let data = payload.data(using: .utf8) else { return false }
        // Record before the writer can emit bytes, so a fast `%begin`/`%end`
        // reply never outruns its local FIFO slot. If the bounded writer rejects
        // the payload, remove the whole batch immediately and reconnect.
        let pendingStart = pendingCommands.count
        pendingCommands.append(contentsOf: kinds)
        guard stdinWriter.enqueue(data) else {
            pendingCommands.removeSubrange(pendingStart...)
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

    private func handleStderrBackpressureOverflow() {
        switch connectionState {
        case .connecting, .connected:
            record("stderr-backpressure")
            beginReconnecting()
        case .reconnecting:
            // This attempt's diagnostic stream is incomplete, so it cannot
            // safely decide whether the session is gone. Abort the attempt and
            // retry with a fresh bounded stream instead of attaching with lost
            // stderr or waiting indefinitely for stdout to end.
            guard process != nil else { return }
            record("reconnect-stderr-backpressure")
            teardownProcessHandles()
            scheduleReconnectAttempt()
        case .ended:
            return
        }
    }

    private func ingest(_ data: Data) {
        for message in parser.feed(data) {
            handle(message)
        }
    }

    private func handleStreamEnd(processGeneration generation: UInt64) async {
        guard generation == processGeneration else { return }
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
            // A teardown or state change may have raced the drain (e.g. deliberate
            // stop or stderr overflow aborting this reconnect attempt).
            guard generation == processGeneration,
                  connectionState == .reconnecting else { return }
            // Classify: a session/server found gone is a genuine end; anything else
            // (host unreachable, refused) is transient — keep retrying with backoff.
            let sessionGone = decoding.stderrIndicatesSessionGone(stderrBuffer)
                || decoding.controlOutputIndicatesSessionGone(preControlOutputBuffer)
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

    /// Freezes the mirror and reconnects after an unusable control stream.
    func beginReconnecting() {
        guard connectionState == .connected || connectionState == .connecting else { return }
        record("reconnecting")
        // The stream is dead: a close decision awaiting an activity query must
        // not hang for the whole backoff window — fail it onto the cache now.
        failPendingActivityQueries()
        failPendingNewWindowRequests()
        failPendingWindowReorderVerifications()
        failPendingTrackedSends()
        resetWindowListRequestCoalescing()
        cancelSizingFollowUps()
        // Subscriptions belong to the dying client, so forget them HERE, not in
        // the reseed: the reconnect's list-windows restage is what re-issues them
        // (see stagePendingLayout), and that restage runs BEFORE
        // reseedAfterReconnect — clearing there would let every surviving window
        // skip its resubscribe and leave `pane-border-status` unwatched for the
        // rest of the connection's life.
        borderStatusSubscribedWindows.removeAll()
        borderStatusByWindow.removeAll()
        pendingPostAttachAction = nil
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
    func handle(_ message: RemoteTmuxControlMessage) {
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
            let closingPaneIDs = Set(windowsByID[id]?.paneIDsInOrder ?? [])
                .union(pendingLayouts[id]?.node.paneIDsInOrder ?? [])
            paneIDsRetainedUntilWindowList.formUnion(closingPaneIDs)
            // Release the closed window's per-window sizing state: a stale
            // entry would be replayed by the reconnect reseed, and a pending
            // debounce could still fire at a dead @id target.
            removeWindowSizeClaim(windowId: id)
            windowSizeDebounceTasks[id]?.cancel()
            windowSizeDebounceTasks[id] = nil
            // Drop the dead window's border-status watch (tmux releases a dead
            // window's subscriptions too; this keeps the client's set tidy across
            // window churn and lets a reused @id resubscribe).
            if borderStatusSubscribedWindows.remove(id) != nil {
                unsubscribeWindowBorderStatus(windowId: id)
            }
            // Release the closed window's per-pane/per-window diagnostic state so
            // it doesn't accumulate across window churn.
            if let closing = windowsByID[id] {
                for pane in closing.paneIDsInOrder {
                    paneOutputByteCounts[pane] = nil
                    paneForegroundStates[pane] = nil
                    paneHeaderLabels[pane] = nil
                }
            }
            activePaneByWindow[id] = nil
            removePublishedPaneOwnership(windowId: id)
            windowsByID[id] = nil
            windowTitleRowPlacements[id] = nil
            windowOrder.removeAll { $0 == id }
            #if DEBUG
            cmuxDebugLog("remote.window.close @\(id) order=\(windowOrder)")
            #endif
            pendingLayouts[id] = nil
            initialBatchStaged[id] = nil
            finishInitialBatchMember(id)
            record("window-close @\(id)")
            // A move of the window's final pane reports the source close before
            // the destination layout. Re-list atomically so observers reconcile
            // against the destination's pending tree instead of pruning the
            // surviving pane during that event gap.
            requestWindows()
            // Remove the closed window's tab immediately. The retained-pane
            // ledger above keeps any moved pane's control identity alive until
            // the authoritative window snapshot publishes its destination.
            observers.notifyTopologyChanged()
        case let .windowRenamed(id, name):
            record("window-renamed @\(id)")
            // Update published AND quarantined topology. A rename racing a
            // pane-rects fetch must survive that fetch's later publication.
            if applyWindowName(windowId: id, name: name) {
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
            } else if name.hasPrefix(Self.borderStatusSubscriptionPrefix),
                      let windowId = Int(name.dropFirst(Self.borderStatusSubscriptionPrefix.count)) {
                // `pane-border-status` changed: every pane touching the configured
                // edge just resized (and top-edge panes moved down) with no
                // %layout-change to announce it, so the published heights are now
                // stale. Re-read the topology — list-windows restages each window
                // and its rects fetch republishes the real geometry, which is the
                // same path a genuine layout event takes. Only a CHANGE refetches:
                // tmux pushes the value once on subscribe, and that initial push
                // rides alongside an attach whose rects fetch is already current.
                let status = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let previous = borderStatusByWindow.updateValue(status, forKey: windowId)
                // What to compare the push against. tmux pushes the value once on
                // subscribe, and that first push is NOT automatically a baseline:
                // it arrives up to a second later (tmux coalesces subscription
                // evaluation), so the option can change between the rects fetch and
                // the push, and treating it as a baseline would swallow exactly the
                // change this subscription exists to catch. A published window's
                // placement came from its own rects reply, so it is the truth to
                // compare the first push against. With no published tree yet the
                // in-flight rects fetch still carries the truth, so the push is a
                // baseline for real.
                let baseline: String? = previous
                    ?? (windowsByID[windowId] != nil
                        ? (windowTitleRowPlacements[windowId]?.rawValue ?? "off")
                        : nil)
                if let baseline, baseline != status {
                    record("border-status @\(windowId) \(baseline)->\(status)")
                    #if DEBUG
                    cmuxDebugLog("remote.border.change @\(windowId) \(baseline)->\(status) refetching")
                    #endif
                    requestWindows()
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
        case .ignoredNotification:
            break
        case let .unparsed(line):
            if connectionState == .reconnecting, !enterReceived {
                preControlOutputBuffer += line + "\n"
                if preControlOutputBuffer.utf8.count > Self.maxStderrBytes {
                    preControlOutputBuffer = String(
                        decoding: preControlOutputBuffer.utf8.suffix(Self.maxStderrBytes),
                        as: UTF8.self
                    )
                }
            }
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

}
