import CmuxRemoteWorkspace
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
    private let observers = RemoteTmuxConnectionObservers()

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
                connectionWaiters.finishAll(connected: true)
            case .ended:
                connectionWaiters.finishAll(connected: false)
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
    private(set) var windowsByID: [Int: RemoteTmuxWindow] = [:]
    private(set) var windowOrder: [Int] = []
    private(set) var activePaneByWindow: [Int: Int] = [:]
    private(set) var paneOutputByteCounts: [Int: Int] = [:]
    private(set) var totalOutputBytes = 0
    /// Last-known foreground classification per pane, kept current by the same
    /// one-shot query + live subscription that drive reflow classification
    /// (`#{alternate_on}` + `#{pane_current_command}`, see
    /// ``requestPaneReflow(paneId:)``). Read at close time to decide whether
    /// killing a mirrored pane/window needs a confirmation dialog — a mirror
    /// surface has no local child process for ghostty's needs-confirm check.
    private(set) var paneForegroundStates: [Int: PaneForegroundState] = [:]
    /// In-flight close-time activity queries by token (see
    /// ``queryWindowActivity(windowId:completion:)``). Failed with `nil` when the
    /// control stream becomes unusable, so a pending close decision falls back to
    /// the cached classification instead of hanging until a reconnect that may
    /// never come.
    private var activityQueryCompletions: [UUID: ([Int: PaneForegroundState]?) -> Void] = [:]

    private var process: Process?
    private var stdinWriter: RemoteTmuxControlPipeWriter?
    private var stdoutReader: FileHandle?
    private var stderrReader: FileHandle?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    /// Consumes the current spawn's stderr into `stderrBuffer`. Awaited before a
    /// failed reconnect attempt is classified, so the decision sees the complete
    /// error rather than racing the async stderr delivery.
    private var stderrTask: Task<Void, Never>?
    private var parser = RemoteTmuxControlStreamParser()
    private var ingestTask: Task<Void, Never>?
    private var pendingCommands: [CommandKind] = []
    private let connectionWaiters = RemoteTmuxConnectionWaiters()
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
    private let decoding = RemoteTmuxControlMessageDecoding()
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
    /// Client-size + attach-redraw-kick (SIGWINCH) sub-model. Owns the debounced
    /// `refresh-client -C` send (coalescing SwiftUI layout-settle oscillation into one
    /// send) and the one-shot attach redraw kick. This connection drives it through
    /// the ``RemoteTmuxClientSizeHost`` conformance below and attaches itself in `init`.
    private let clientSize = RemoteTmuxClientSizeController()
    private var pendingPostAttachAction: PostAttachAction?

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
    /// Cap pending stdout chunks between SSH's pipe callback and the main-actor
    /// parser. A full buffer means parsing/rendering has fallen behind remote
    /// output; reconnecting and re-seeding is safer than corrupting the stream by
    /// dropping arbitrary control-mode bytes or growing memory without bound.
    private static let maxPendingStdoutChunks = 16

    /// Pure builders for the tmux control-mode command strings this connection
    /// writes, plus the parser for the activity-query lines it reads back. Holds
    /// the subscription-name prefixes (`cmux_cwd_`/`cmux_reflow_`) and the
    /// activity-query format, defined once so the writer side (subscribe) and the
    /// reader side (unsubscribe / `%subscription-changed` routing / activity
    /// parse) can't drift.
    let commandBuilder = RemoteTmuxControlCommandBuilder()

    /// `ESC[?1049h` — enter the alternate screen, emitted to a mirror surface when
    /// the remote pane is on the alternate screen (see ``capturePane(paneId:)``).
    private static let altScreenEnterSequence = Data("\u{1b}[?1049h".utf8)
    private static let altScreenExitSequence = Data("\u{1b}[?1049l".utf8)

    init(host: RemoteTmuxHost, sessionName: String, createIfMissing: Bool = false) {
        self.host = host
        self.sessionName = sessionName
        self.createIfMissing = createIfMissing
        clientSize.attach(host: self)
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
    ///   - onSessionChanged: fires when tmux confirms a session rename via
    ///     `%session-changed`.
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

                connectionWaiters.register(token) { connected in
                    continuation.resume(returning: connected)
                }

                if Task.isCancelled {
                    connectionWaiters.finish(token, connected: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.connectionWaiters.finish(token, connected: false)
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
        // Normally already flushed by beginReconnecting; kept here so a future
        // caller of spawnProcess can't strand a close decision.
        failPendingActivityQueries()
        attachBlockDrained = false
        stderrBuffer = ""
        enterReceived = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
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

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maxPendingStdoutChunks)
        )
        let reader = outPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }

            switch continuation.yield(chunk) {
            case .enqueued:
                break
            case .dropped, .terminated:
                handle.readabilityHandler = nil
                continuation.finish()
                Task { @MainActor [weak self] in
                    self?.handleStdoutBackpressureOverflow()
                }
            @unknown default:
                handle.readabilityHandler = nil
                continuation.finish()
                Task { @MainActor [weak self] in
                    self?.handleStdoutBackpressureOverflow()
                }
            }
        }
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
            continuation.finish()
            errContinuation.finish()
        }

        do {
            try proc.run()
        } catch {
            // Don't latch `started` on a failed launch, so a later attach can
            // replace this connection instead of reusing a dead one. Close the
            // stdin writer too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            reader.readabilityHandler = nil
            errReader.readabilityHandler = nil
            continuation.finish()
            errContinuation.finish()
            stdinWriter.close()
            throw error
        }
        process = proc
        self.stdinWriter = stdinWriter
        stdoutReader = reader
        stderrReader = errReader
        streamContinuation = continuation
        stderrContinuation = errContinuation
        stderrTask = Task { [weak self] in
            for await chunk in errStream {
                guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { continue }
                self?.appendStderr(text)
            }
        }
        ingestTask = Task { [weak self] in
            for await chunk in stream {
                self?.ingest(chunk)
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

    /// Sizes the tmux control client to `columns`×`rows` cells (tmux
    /// `refresh-client -C`) so the remote windows/panes reflow to the rendered
    /// cmux grid. Without this a freshly attached session stays at ssh's default
    /// 80×24 and TUIs (claude, claude agents) render mangled. Always records the grid
    /// (re-applied by ``reseedAfterReconnect()``); sends the live `refresh-client`
    /// only while `.connected`. No-ops for a degenerate grid.
    ///
    /// This is the single sizing entrypoint every remote-tmux render path routes
    /// through (the single-pane display surface and the multi-pane window mirror),
    /// so client sizing stays one shared behavior rather than duplicated sends.
    func setClientSize(columns: Int, rows: Int) {
        clientSize.setClientSize(columns: columns, rows: rows)
    }

    /// Requests the current window list + layouts (used to (re)build topology).
    ///
    /// `#{window_name}` is placed last because it can contain spaces, while the
    /// id and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func requestWindows() {
        sendInternal(
            commandBuilder.listWindowsCommand(),
            kind: .listWindows
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
            commandBuilder.paneAlternateScreenQueryCommand(paneId: paneId),
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
        sendInternal(commandBuilder.capturePaneCommand(paneId: paneId), kind: .capturePane(paneId))
        // Query the pane's terminal STATE; tmux exposes it all as formats. Sent
        // after capture-pane so it applies on top of the painted rows (the seed
        // escapes are built in `paneStateSeedSequence`). See the doc comment for why
        // restoring this matters.
        sendInternal(
            commandBuilder.paneStateQueryCommand(paneId: paneId),
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
    }

    /// One-shot query of a pane's working directory (`pane_current_path`),
    /// delivered to the cwd observers. Guarantees an initial folder for the
    /// mirrored tab even on tmux builds without control-mode subscriptions.
    func requestPanePath(paneId: Int) {
        sendInternal(
            commandBuilder.panePathQueryCommand(paneId: paneId),
            kind: .panePath(paneId)
        )
    }

    /// Subscribes to live `pane_current_path` changes for `paneId` via tmux
    /// control-mode `refresh-client -B`, so a remote `cd` updates the mirrored
    /// tab's folder without polling. tmux emits the value once on subscribe and
    /// again on every change as `%subscription-changed cmux_cwd_<paneId> … : <path>`.
    /// Best-effort: on tmux builds that don't support subscriptions the command is
    /// a no-op and ``requestPanePath(paneId:)`` still supplies the initial folder.
    func subscribePanePath(paneId: Int) {
        send(commandBuilder.panePathSubscriptionCommand(paneId: paneId))
    }

    /// Removes the live `pane_current_path` subscription for `paneId` (issued once
    /// the pane is gone). tmux also drops a dead pane's subscriptions on its own;
    /// this keeps the client's subscription set tidy across split/close churn.
    func unsubscribePanePath(paneId: Int) {
        send(commandBuilder.panePathUnsubscribeCommand(paneId: paneId))
    }

    /// One-shot query of a pane's reflow classification (`#{alternate_on}` +
    /// `#{pane_current_command}`), delivered to the reflow observers. This is the
    /// REQUIRED initial classifier — `subscribePaneReflow` only guarantees *live*
    /// updates, and on tmux builds where the `-B` subscription doesn't deliver this
    /// combined value the surface would otherwise stay at its safe no-reflow default
    /// forever (shells never reflow). Mirrors ``requestPanePath(paneId:)`` exactly
    /// (a `display-message` always works where a subscription might not).
    func requestPaneReflow(paneId: Int) {
        sendInternal(
            commandBuilder.paneReflowQueryCommand(paneId: paneId),
            kind: .paneReflow(paneId)
        )
    }

    /// Classifies a raw `#{alternate_on}|#{pane_current_command}` value (from the
    /// one-shot query or a live subscription), records it as the pane's foreground
    /// state (for the close-confirmation check), and emits the no-reflow decision.
    /// No-reflow when on the alternate screen OR the foreground command isn't a known
    /// plain shell; defaults to no-reflow on an empty/unparseable value (safe).
    private func classifyAndEmitReflow(paneId: Int, rawValue: String, source: String) {
        let state = PaneForegroundState(rawValue: rawValue)
        paneForegroundStates[paneId] = state
        let noReflow = state.suppressesReflow
        #if DEBUG
        cmuxDebugLog(
            "remote.reflow.classify pane=\(paneId) src=\(source) raw=\"\(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                + "alt=\(state.alternateOn ? 1 : 0) cmd=\"\(state.command)\" noReflow=\(noReflow ? 1 : 0)"
        )
        #endif
        observers.emitPaneReflow(paneId, noReflow)
    }

    /// Subscribes to live reflow-classification changes for `paneId` via tmux
    /// control-mode `refresh-client -B`. The subscribed value is
    /// `#{alternate_on}|#{pane_current_command}`; tmux emits it once on subscribe
    /// and again whenever it changes, so a pane that switches between a plain shell
    /// and an inline TUI (e.g. bash → node when claude launches) is reclassified
    /// without polling. The mirror surface uses this to decide whether to reflow its
    /// primary screen on resize (shells reflow; alt-screen / inline-TUI panes do
    /// not), and the close confirmation uses it to track the active foreground
    /// command. Best-effort: on tmux builds without subscriptions this is a no-op and
    /// the surface keeps its safe no-reflow default. See ``subscriptionChanged``
    /// handling for the parse, and ``PaneForegroundState/plainShellCommands`` for the policy.
    func subscribePaneReflow(paneId: Int) {
        send(commandBuilder.paneReflowSubscriptionCommand(paneId: paneId))
    }

    /// Removes the live reflow-classification subscription for `paneId` (issued once
    /// the pane is gone), mirroring ``unsubscribePanePath(paneId:)``.
    func unsubscribePaneReflow(paneId: Int) {
        send(commandBuilder.paneReflowUnsubscribeCommand(paneId: paneId))
    }

    /// Live, close-time query of every pane's foreground state in `windowId`.
    /// tmux evaluates `pane_current_command` AT QUERY TIME, so a command started
    /// the instant before ⌘W is already visible — unlike the `%subscription-changed`
    /// cache, which tmux only re-checks about once a second. Results also refresh
    /// ``paneForegroundStates`` so the synchronous consumers (batch close,
    /// workspace close, quit warning) get the freshness for free. `completion` is
    /// called exactly once, on the main actor; `nil` means the query could not be
    /// issued or the stream reset first (caller falls back to the cache).
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: PaneForegroundState]?) -> Void) {
        sendActivityQuery(commandBuilder.windowActivityQueryCommand(windowId: windowId), completion: completion)
    }

    /// Single-pane variant of ``queryWindowActivity(windowId:completion:)``, for
    /// the multi-pane mirror's pane-header ✕ close.
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: PaneForegroundState]?) -> Void) {
        sendActivityQuery(commandBuilder.paneActivityQueryCommand(paneId: paneId), completion: completion)
    }

    private func sendActivityQuery(
        _ command: String, completion: @escaping ([Int: PaneForegroundState]?) -> Void
    ) {
        guard connectionState == .connected else {
            completion(nil)
            return
        }
        let token = UUID()
        activityQueryCompletions[token] = completion
        guard sendInternal(command, kind: .activityQuery(token)) else {
            // The stream could not accept the query, so no result can correlate.
            // Fail now and let the close decision proceed on the cached state.
            activityQueryCompletions.removeValue(forKey: token)?(nil)
            return
        }
    }

    /// Fails every in-flight activity query — called whenever the control stream
    /// becomes unusable (reconnect begins, deliberate stop, genuine `%exit`), so
    /// a pending close decision falls back to the cached classification.
    private func failPendingActivityQueries() {
        guard !activityQueryCompletions.isEmpty else { return }
        let completions = Array(activityQueryCompletions.values)
        activityQueryCompletions.removeAll()
        for completion in completions { completion(nil) }
    }

    /// Sends literal key bytes to a pane via tmux `send-keys -H` (hex-encoded),
    /// which is binary-safe and needs no shell quoting.
    @discardableResult
    func sendKeys(paneId: Int, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return sendInternal(commandBuilder.sendKeysCommand(paneId: paneId, data: data), kind: .other)
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
        guard let commands = commandBuilder.pastePaneCommands(paneId: paneId, text: text) else { return false }
        return send(commands.setBuffer) && send(commands.pasteBuffer)
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
        clientSize.reset()
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
        stdoutReader?.readabilityHandler = nil
        stdoutReader = nil
        stderrReader?.readabilityHandler = nil
        stderrReader = nil
        streamContinuation?.finish()
        streamContinuation = nil
        stderrContinuation?.finish()
        stderrContinuation = nil
        stdinWriter?.close()
        stdinWriter = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Internals

    @discardableResult
    private func sendInternal(_ command: String, kind: CommandKind) -> Bool {
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
    private func reseedAfterReconnect() {
        if let size = clientSize.lastClientSize {
            send(commandBuilder.clientResizeCommand(columns: size.columns, rows: size.rows))
        }
        // The re-applied size is usually a no-op (the server kept the window at our
        // size across the transport drop), so TUIs get no SIGWINCH — kick them so
        // they repaint over the re-seeded (possibly stale) frame. FIFO-safe: the
        // captures below are queued before the kick task's first push can run.
        clientSize.scheduleAttachRedrawKickIfNeeded()
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
                clientSize.armAttachRedrawKick()
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
            guard let safeName = RemoteTmuxHost.controlModeLineSafeName(name) else {
                record("session-changed-invalid $\(id)")
                requestWindows()
                return
            }
            let oldName = sessionName
            sessionId = id
            // Track the new name too: `sessionName` is the value reused for
            // attach/reconnect, so a remote rename must update it or the next
            // reconnect targets a stale session and is wrongly declared gone.
            sessionName = safeName
            record("session-changed $\(id)")
            observers.emitSessionChanged(oldName: oldName, newName: safeName)
            requestWindows()
        case .sessionsChanged:
            record("sessions-changed")
        case let .windowAdd(id):
            record("window-add @\(id)")
            requestWindows()
        case let .windowClose(id):
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
            windowOrder.removeAll { $0 == id }
            record("window-close @\(id)")
            observers.notifyTopologyChanged()
        case let .windowRenamed(id, name):
            record("window-renamed @\(id)")
            // Propagate the new name into the topology so the mirrored tab title
            // refreshes. Keep the existing geometry/layout.
            if let existing = windowsByID[id], existing.name != name {
                windowsByID[id] = RemoteTmuxWindow(
                    id: id, name: name,
                    width: existing.width, height: existing.height, layout: existing.layout
                )
                observers.notifyTopologyChanged()
            }
        case let .layoutChange(id, layout):
            applyLayout(windowId: id, layout: layout)
            record("layout-change @\(id)")
            observers.notifyTopologyChanged()
        case let .windowPaneChanged(windowId, paneId):
            activePaneByWindow[windowId] = paneId
            observers.emitActivePaneChanged(windowId, paneId)
        case let .sessionWindowChanged(_, windowId):
            record("session-window-changed @\(windowId)")
        case let .subscriptionChanged(name, value):
            // cmux subscribes each pane's working directory as "cmux_cwd_<paneId>".
            if name.hasPrefix(commandBuilder.cwdSubscriptionPrefix),
               let paneId = Int(name.dropFirst(commandBuilder.cwdSubscriptionPrefix.count)) {
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { observers.emitPaneCwd(paneId, path) }
            } else if name.hasPrefix(commandBuilder.reflowSubscriptionPrefix),
                      let paneId = Int(name.dropFirst(commandBuilder.reflowSubscriptionPrefix.count)) {
                // Reflow classification: "<alternate_on>|<pane_current_command>".
                classifyAndEmitReflow(paneId: paneId, rawValue: value, source: "sub")
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

    private func handleCommandResult(lines: [String], isError: Bool) {
        // The attach block was already consumed upstream (`attachBlockDrained`);
        // an empty FIFO here means an unsolicited block — drop it rather than
        // misalign the positional correlation.
        guard !pendingCommands.isEmpty else { return }
        let kind = pendingCommands.removeFirst()
        guard !isError else {
            // An errored activity query must still complete (with nil) — a close
            // decision is waiting on it and falls back to the cached state.
            if case let .activityQuery(token) = kind,
               let completion = activityQueryCompletions.removeValue(forKey: token) {
                completion(nil)
            }
            // Errors are dropped by design (results correlate positionally), but
            // an invisible %error has already hidden one real bug — an unquoted
            // refresh-client -B that never subscribed — so leave a trace.
            #if DEBUG
            cmuxDebugLog(
                "remote.tmux.commandError kind=\(kind) error=\"\(lines.joined(separator: " / "))\""
            )
            #endif
            return
        }
        switch kind {
        case .listWindows:
            var order: [Int] = []
            var next: [Int: RemoteTmuxWindow] = [:]
            for line in lines {
                // "@<id> <layout> <name with spaces…>" — id and layout never
                // contain spaces, so split into at most 3 fields.
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count >= 2,
                      let id = RemoteTmuxControlStreamParser.id(parts[0], sigil: "@"),
                      let node = RemoteTmuxRawLayoutParser.parse(String(parts[1]))
                else { continue }
                let name = parts.count >= 3 ? String(parts[2]) : ""
                next[id] = RemoteTmuxWindow(
                    id: id, name: name, width: node.width, height: node.height, layout: node
                )
                order.append(id)
            }
            // Ignore an empty/garbled reply on purpose: a live tmux session always
            // has ≥1 window, so a zero-window parse is a transient or malformed
            // result, not a real topology. Acting on it would wipe `windowOrder`
            // and tear down every mirror tab. A genuine "no windows" state means
            // the session ended — that arrives as the connection's `%exit` /
            // stream-end (see `handleConnectionExited` → `handleSessionEndedRemotely`),
            // which is the path that closes the workspace / dedicated window.
            if !order.isEmpty {
                // Replace topology instead of merging: a remote close missed while
                // disconnected leaves no %window-close, so prune stale panes here.
                let liveIDs = Set(order)
                windowsByID = next
                activePaneByWindow = activePaneByWindow.filter { liveIDs.contains($0.key) }
                prunePaneState(keeping: Set(next.values.flatMap { $0.paneIDsInOrder }))
                windowOrder = order
                observers.notifyTopologyChanged()
                // The attach block is drained and the topology is fresh — run the
                // deferred post-attach work; commands queued here correlate cleanly
                // (see ``PostAttachAction``).
                switch pendingPostAttachAction {
                case .reseed:
                    reseedAfterReconnect()
                case .applyClientSize:
                    // A surface that hasn't computed a grid yet is covered by the
                    // debounced `setClientSize` instead.
                    if let size = clientSize.lastClientSize {
                        send(commandBuilder.clientResizeCommand(columns: size.columns, rows: size.rows))
                    }
                case nil:
                    break
                }
                pendingPostAttachAction = nil
                // First-connect coverage for the attach redraw kick: if the grid was
                // computed before `.enter`, no post-connect `setClientSize` may ever
                // fire (layout settled + same-size dedupe upstream), so the
                // debounced-send consumer never runs. This is the earliest point with
                // populated topology — and `windowsByID` was parsed from THIS
                // list-windows reply, generated before tmux processed the size apply
                // just queued above, so the at-target check sees the true pre-apply
                // geometry. No-op when the kick was already consumed (or when
                // reseedAfterReconnect just ran it).
                clientSize.scheduleAttachRedrawKickIfNeeded()
            }
        case let .capturePane(paneId):
            // capture-pane -e -S output is the pane's history + visible rows (with
            // SGR escapes). Home + clear the VISIBLE SCREEN (ESC[2J — NOT ESC[3J,
            // which would erase the scrollback we are seeding), then write every
            // captured row joined by CR LF: rows that overflow the screen scroll up
            // into the surface's scrollback buffer, which is what makes the mirrored
            // tab scrollable from the start. The last row (the visible bottom) gets
            // no trailing newline so the cursor lands at its END, lining up with
            // tmux's real prompt cursor — otherwise echoed input lands a line below
            // the prompt. The `.paneState` seed then repositions the cursor within
            // the visible screen.
            let painted = "\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n")
            if let data = painted.data(using: .utf8) {
                observers.emitPaneOutput(paneId, data)
            }
        case let .paneState(paneId):
            // Restore the pane's terminal state (scroll region + DEC modes + cursor)
            // onto the mirror surface, applied after the capture paint. The scroll
            // region (DECSTBM) is the important one: without it an inline TUI's
            // region-relative redraws land on the wrong rows even at a static size.
            if let line = lines.first {
                observers.emitPaneOutput(paneId, decoding.paneStateSeedSequence(from: line))
            }
        case let .panePath(paneId):
            if let path = lines.first?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                observers.emitPaneCwd(paneId, path)
            }
        case let .paneReflow(paneId):
            // One-shot reflow classification result (see requestPaneReflow). Empty
            // lines → classifyAndEmitReflow defaults to no-reflow (safe).
            classifyAndEmitReflow(paneId: paneId, rawValue: lines.first ?? "", source: "oneshot")
        case let .activityQuery(token):
            guard let completion = activityQueryCompletions.removeValue(forKey: token) else { break }
            var states: [Int: PaneForegroundState] = [:]
            for line in lines {
                guard let parsed = commandBuilder.parseActivityQueryLine(line) else { continue }
                states[parsed.paneId] = parsed.state
            }
            // The fresh answer flows back into the cache, so the synchronous
            // consumers (batch close, workspace close, quit warning) benefit too.
            for (paneId, state) in states { paneForegroundStates[paneId] = state }
            completion(states)
        case let .paneAltScreen(paneId):
            // Match the mirror surface to the remote pane's screen (alt = no reflow on
            // resize). Emitted before the capture paint that follows in the FIFO, so the
            // seeded rows land on the right screen. The else branch is load-bearing on a
            // surface REUSED across reconnect: if it was on the alt screen before and the
            // remote pane is now on primary, force it back (1049l) so the capture doesn't
            // paint onto a stale alt screen.
            if lines.first?.trimmingCharacters(in: .whitespaces) == "1" {
                observers.emitPaneOutput(paneId, Self.altScreenEnterSequence)
            } else {
                observers.emitPaneOutput(paneId, Self.altScreenExitSequence)
            }
        case .other:
            break
        }
    }

    private func applyLayout(windowId: Int, layout: String) {
        guard let node = RemoteTmuxRawLayoutParser.parse(layout) else { return }
        // Preserve any name tmux already reported (a %layout-change carries no name).
        let existingName = windowsByID[windowId]?.name ?? ""
        windowsByID[windowId] = RemoteTmuxWindow(
            id: windowId, name: existingName, width: node.width, height: node.height, layout: node
        )
        if !windowOrder.contains(windowId) { windowOrder.append(windowId) }
        prunePaneState(keeping: Set(windowsByID.values.flatMap { $0.paneIDsInOrder }))
    }

    private func prunePaneState(keeping livePanes: Set<Int>) {
        paneOutputByteCounts = paneOutputByteCounts.filter { livePanes.contains($0.key) }
        paneForegroundStates = paneForegroundStates.filter { livePanes.contains($0.key) }
    }

    private func record(_ event: String) {
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

// MARK: - RemoteTmuxClientSizeHost

/// Command/state seam the ``clientSize`` sub-model drives. Keeps the window/pane
/// geometry (`windowsByID`, the app-only ``RemoteTmuxWindow``) and the app's
/// `cmuxDebugLog` on this side, exposing only plain `Int`/`Bool`/`String` to the
/// package controller.
extension RemoteTmuxControlConnection: RemoteTmuxClientSizeHost {
    var isClientSizeConnectionConnected: Bool { connectionState == .connected }

    var hasMirroredWindowTopology: Bool { !windowsByID.isEmpty }

    func mirroredWindowMatchesClientSize(columns: Int, rows: Int) -> Bool {
        windowsByID.values.contains { $0.width == columns && $0.height == rows }
    }

    func sendClientSizeCommand(_ command: String) {
        send(command)
    }

    func clientSizeApplyDidCoverPendingPostAttachAction() {
        if pendingPostAttachAction == .applyClientSize {
            pendingPostAttachAction = nil
        }
    }

    func logClientSizeEvent(_ message: @autoclosure () -> String) {
        #if DEBUG
        cmuxDebugLog(message())
        #endif
    }
}
