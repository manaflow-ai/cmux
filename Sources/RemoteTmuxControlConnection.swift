import Foundation

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

    private var process: Process?
    private var stdinHandle: FileHandle?
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
    /// Last client size applied via ``setClientSize(columns:rows:)``, re-applied
    /// after a reconnect so the resumed session keeps the mirror's grid instead of
    /// reverting to ssh's default 80×24.
    private var lastClientSize: (columns: Int, rows: Int)?
    /// Set when a reconnect reaches control mode; the actual pane re-seed is deferred
    /// to the first post-reconnect `list-windows` result so it can't queue commands
    /// before the attach's own `%begin`/`%end` block is consumed (which would misalign
    /// the command-result FIFO).
    private var pendingReconnectReseed = false
    /// Set on a FIRST connect whose `.enter` arrived with a grid already stored (or
    /// not yet computed); the `refresh-client -C` re-apply is deferred to the first
    /// `list-windows` result for the same FIFO reason as ``pendingReconnectReseed``
    /// — `.enter` precedes the attach block, and any command queued before that
    /// block is consumed would shift the positional result FIFO.
    private var pendingFirstConnectSizeApply = false

    /// Trailing-edge debounce for `refresh-client -C`. SwiftUI layout settle makes the
    /// rendered grid oscillate (e.g. cols 154→155→156→161→…, ~15 distinct grids in
    /// ~1.3s), and each previously sent its own `refresh-client -C` → ~15 SIGWINCH /
    /// redraw storms on the remote per attach. We now coalesce them: ``setClientSize``
    /// stores the size immediately but defers the send to one shot after the size
    /// stops changing. The fired timer is also the clean "size settled" edge that
    /// consumes the one-shot attach redraw kick below.
    private var clientSizeDebounceTask: Task<Void, Never>?
    private static let clientSizeDebounceMs = 180

    /// Armed on every transition to `.connected` (first connect AND reconnect) and
    /// consumed by the first size apply that follows; see
    /// ``scheduleAttachRedrawKickIfNeeded()`` for why attach needs a redraw kick.
    private var pendingAttachRedrawKick = false
    private var attachRedrawKickTask: Task<Void, Never>?
    /// Gap between the kick's shrink push and its restore push. Must exceed tmux's
    /// pane-resize coalescing (~250 ms), otherwise the two pushes collapse into a
    /// net-zero size change and no SIGWINCH is ever delivered.
    private static let attachRedrawKickGapMs = 350

    /// Base reconnect backoff (seconds); doubled each attempt up to ``reconnectMaxDelaySeconds``.
    private static let reconnectBaseDelaySeconds: Double = 1
    /// Cap on the reconnect backoff (seconds). Retries continue indefinitely at this
    /// interval until the network returns or the session is found to be gone.
    private static let reconnectMaxDelaySeconds: Double = 10
    /// Cap on captured stderr (bytes) so a noisy/hostile remote can't grow it unbounded.
    private static let maxStderrBytes = 8 * 1024

    private enum CommandKind: Equatable {
        case listWindows, capturePane(Int), paneState(Int), panePath(Int), paneReflow(Int), paneAltScreen(Int), other
    }

    /// The lifecycle phase of a control connection.
    ///
    /// A transport loss moves `.connected` → `.reconnecting` (the mirror stays
    /// frozen and keeps retrying); a successful re-attach returns to `.connected`
    /// and re-seeds the panes. Only a genuine tmux `%exit`, a session found gone on
    /// reconnect, or a deliberate ``stop()`` reaches `.ended`.
    enum ConnectionState: Sendable, Equatable {
        /// The initial connection is being established (before the first control-mode
        /// `%enter`).
        case connecting
        /// Live: control mode is up and streaming.
        case connected
        /// The transport dropped; retrying with backoff while the mirror stays frozen.
        case reconnecting
        /// Permanently over (genuine `%exit`, session gone, or deliberate stop).
        case ended
    }

    /// Subscription-name prefix for per-pane `pane_current_path` (`refresh-client -B`).
    /// The tmux pane id is appended so an inbound `%subscription-changed` can be
    /// routed back to its pane; defined once so the writer and reader can't drift.
    private static let cwdSubscriptionPrefix = "cmux_cwd_"

    /// Subscription-name prefix for per-pane reflow classification
    /// (`refresh-client -B`). The subscribed format is
    /// `#{alternate_on}<sep>#{pane_current_command}`; tmux emits it on subscribe
    /// and on every change, so launching/exiting an app (bash → node when claude
    /// starts) re-classifies the pane live. The tmux pane id is appended for
    /// routing, mirroring ``cwdSubscriptionPrefix``.
    private static let reflowSubscriptionPrefix = "cmux_reflow_"

    /// Field separator inside the reflow subscription value
    /// (`#{alternate_on}|#{pane_current_command}`). A pipe never appears in a tmux
    /// `alternate_on` flag (0/1) and is not part of a process's `comm` name.
    private static let reflowFieldSeparator: Character = "|"

    /// Foreground commands (`#{pane_current_command}`) whose primary-screen
    /// scrollback is safe to reflow on resize — i.e. plain interactive shells that
    /// keep their history as ordinary soft-wrapped text. Anything else (node for
    /// claude, python, REPLs, pagers, editors) is treated as no-reflow so an inline
    /// TUI's fixed-width frame is never rewrapped. Alt-screen apps are caught
    /// separately by `#{alternate_on}`. Login shells can be reported with a leading
    /// dash, so the common traditional/POSIX dash variants are listed too (not every
    /// shell has one — a missing dash variant just doesn't reflow). Classification
    /// defaults to no-reflow on anything not in this set (and on an unparseable
    /// value), which is the safe direction (worst case: a shell's scrollback doesn't
    /// reflow until reclassified) — so a login shell whose dash variant is missing
    /// here simply doesn't reflow, never breaks.
    private static let reflowSafeShellCommands: Set<String> = [
        "bash", "zsh", "fish", "sh", "dash", "ksh", "tcsh", "csh", "ash",
        "mksh", "pdksh", "elvish", "nu", "xonsh", "pwsh", "powershell", "oil", "osh",
        "-bash", "-zsh", "-fish", "-sh", "-dash", "-ksh", "-tcsh", "-csh", "-ash",
    ]

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
        onTopologyChanged: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onConnectionStateChanged: ((ConnectionState) -> Void)? = nil
    ) -> ObserverToken {
        observers.add(
            onPaneOutput: onPaneOutput,
            onPaneCwd: onPaneCwd,
            onPaneReflow: onPaneReflow,
            onActivePaneChanged: onActivePaneChanged,
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
        stdinHandle = inPipe.fileHandleForWriting

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = outPipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
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
            // stdin handle too, so the connection is left in a clean, retry-safe
            // state instead of holding a dead pipe that silently EPIPEs on write.
            reader.readabilityHandler = nil
            errReader.readabilityHandler = nil
            continuation.finish()
            errContinuation.finish()
            try? stdinHandle?.close()
            stdinHandle = nil
            throw error
        }
        process = proc
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
    func send(_ command: String) {
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
        guard columns > 0, rows > 0 else { return }
        // Remember the grid so a reconnect can re-apply it (a fresh ssh client
        // otherwise reverts to 80×24 and mangles TUIs). Only send now when actually
        // connected — while reconnecting/ended there is no live stdin (the send would
        // silently drop); `reseedAfterReconnect` re-applies the stored size.
        lastClientSize = (columns, rows)
        guard connectionState == .connected else { return }
        // Coalesce the layout-settle oscillation into a single send: (re)arm a short
        // trailing timer; only the last size in a burst actually goes out. The fired
        // timer is also the "settled" edge that consumes the attach redraw kick.
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.clientSizeDebounceMs))
            } catch {
                return
            }
            guard let self, self.connectionState == .connected, let size = self.lastClientSize else { return }
            self.send("refresh-client -C \(size.columns)x\(size.rows)")
            // This send already applied the stored grid — the deferred first-connect
            // apply would only duplicate it.
            self.pendingFirstConnectSizeApply = false
            // Do NOT re-capture here. A re-capture would run capture-pane before the
            // remote app (claude) finishes its post-SIGWINCH redraw, snapshotting the
            // stale pre-resize frame and clobbering the correct redraw — the exact
            // narrow/overlap/duplicate mangle. A manual resize is clean precisely
            // because it issues no capture: it lets refresh-client -C → SIGWINCH →
            // the app's own redraw stream back and paint. Attach does the same.
            self.scheduleAttachRedrawKickIfNeeded()
        }
    }

    /// One-shot, attach-only: force a real SIGWINCH when the attach size push was a
    /// no-op, so a running TUI re-renders the current frame at the current width.
    ///
    /// Why this exists: tmux's grid stores an app's output as it was RENDERED — rows
    /// drawn at an earlier window width, or an inline TUI's streaming churn, stay in
    /// the visible frame verbatim. tmux has no "redraw" command for a control (-CC)
    /// client (`%output` is an append-only pty copy; tmux never re-streams grid
    /// cells), and `capture-pane` re-reads the same stale cells, so the ONLY way to
    /// get a clean current-width frame is the app's own repaint — which apps do on
    /// SIGWINCH. A real-terminal attach virtually always delivers that SIGWINCH
    /// because its size differs from the detached window's size. The mirror's attach
    /// usually does NOT: the window still has the size cmux itself left behind, so
    /// `refresh-client -C` matches it exactly, no pane resize happens, and the stale
    /// frame stays until the user manually resizes. This kick closes that one gap by
    /// sending the same signal a real attach sends: a genuine size change (rows-1),
    /// then the true size after tmux's resize-coalescing window has passed.
    ///
    /// Ordering is safe vs the seed: the kick is scheduled after the capture-pane
    /// commands, and the tmux server processes commands FIFO, so the app's redraw
    /// `%output` always lands after (on top of) the seed paint. Skipped entirely when
    /// the attach push itself changed the window size (that already SIGWINCHes), and
    /// invisible for plain-shell panes (nothing re-renders, nothing is streamed).
    private func scheduleAttachRedrawKickIfNeeded() {
        guard pendingAttachRedrawKick else { return }
        // Not ready yet (no grid computed / topology not drained): keep the one-shot
        // armed for the next size apply instead of consuming it uselessly.
        guard connectionState == .connected, let size = lastClientSize, !windowsByID.isEmpty else { return }
        pendingAttachRedrawKick = false
        guard size.rows > 2 else { return }
        // Only kick when some mirrored window ALREADY has the target size — i.e. the
        // size apply above cannot produce a SIGWINCH for it. (window-size latest makes
        // every window track the client, so one client-level kick redraws them all.)
        let windowAlreadyAtTarget = windowsByID.values.contains {
            $0.width == size.columns && $0.height == size.rows
        }
        guard windowAlreadyAtTarget else {
            #if DEBUG
            cmuxDebugLog("remote.size.kick skip=windowSizeDiffers target=\(size.columns)x\(size.rows)")
            #endif
            return
        }
        #if DEBUG
        cmuxDebugLog("remote.size.kick shrink to \(size.columns)x\(size.rows - 1)")
        #endif
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = Task { @MainActor [weak self] in
            guard let self, self.connectionState == .connected else { return }
            // Bail if the user resized since the kick was scheduled: that resize is a
            // real size change, so it already delivered the SIGWINCH this kick exists
            // to force — and a shrink at the captured (now stale) size would flash
            // wrong dimensions at the remote apps.
            guard let current = self.lastClientSize, current == size else { return }
            self.send("refresh-client -C \(size.columns)x\(size.rows - 1)")
            do {
                try await ContinuousClock().sleep(for: .milliseconds(Self.attachRedrawKickGapMs))
            } catch {
                return
            }
            guard self.connectionState == .connected else { return }
            // Restore the CURRENT size (the user may have resized during the gap).
            let restore = self.lastClientSize ?? size
            #if DEBUG
            cmuxDebugLog("remote.size.kick restore to \(restore.columns)x\(restore.rows)")
            #endif
            self.send("refresh-client -C \(restore.columns)x\(restore.rows)")
        }
    }

    /// Requests the current window list + layouts (used to (re)build topology).
    ///
    /// `#{window_name}` is placed last because it can contain spaces, while the
    /// id and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func requestWindows() {
        sendInternal(
            "list-windows -F \"#{window_id} #{window_layout} #{window_name}\"",
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

    /// One-shot query of a pane's working directory (`pane_current_path`),
    /// delivered to the cwd observers. Guarantees an initial folder for the
    /// mirrored tab even on tmux builds without control-mode subscriptions.
    func requestPanePath(paneId: Int) {
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{pane_current_path}\"",
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
        send("refresh-client -B \(Self.cwdSubscriptionPrefix)\(paneId):%\(paneId):#{pane_current_path}")
    }

    /// Removes the live `pane_current_path` subscription for `paneId` (issued once
    /// the pane is gone). tmux also drops a dead pane's subscriptions on its own;
    /// this keeps the client's subscription set tidy across split/close churn.
    func unsubscribePanePath(paneId: Int) {
        send("refresh-client -B \(Self.cwdSubscriptionPrefix)\(paneId)")
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
            "display-message -p -t %\(paneId) -F \""
                + "#{alternate_on}\(Self.reflowFieldSeparator)#{pane_current_command}\"",
            kind: .paneReflow(paneId)
        )
    }

    /// Classifies a raw `#{alternate_on}|#{pane_current_command}` value (from the
    /// one-shot query or a live subscription) and emits the no-reflow decision.
    /// No-reflow when on the alternate screen OR the foreground command isn't a known
    /// plain shell; defaults to no-reflow on an empty/unparseable value (safe).
    private func classifyAndEmitReflow(paneId: Int, rawValue: String, source: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: Self.reflowFieldSeparator, maxSplits: 1, omittingEmptySubsequences: false
        )
        let altOn = parts.first.map(String.init) == "1"
        let command = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
        let noReflow = altOn || !Self.reflowSafeShellCommands.contains(command)
        #if DEBUG
        cmuxDebugLog(
            "remote.reflow.classify pane=\(paneId) src=\(source) raw=\"\(trimmed)\" "
                + "alt=\(altOn ? 1 : 0) cmd=\"\(command)\" noReflow=\(noReflow ? 1 : 0)"
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
    /// not). Best-effort: on tmux builds without subscriptions this is a no-op and
    /// the surface keeps its safe no-reflow default. See ``subscriptionChanged``
    /// handling for the parse, and ``reflowSafeShellCommands`` for the policy.
    func subscribePaneReflow(paneId: Int) {
        send(
            "refresh-client -B \(Self.reflowSubscriptionPrefix)\(paneId):%\(paneId):"
                + "#{alternate_on}\(Self.reflowFieldSeparator)#{pane_current_command}"
        )
    }

    /// Removes the live reflow-classification subscription for `paneId` (issued once
    /// the pane is gone), mirroring ``unsubscribePanePath(paneId:)``.
    func unsubscribePaneReflow(paneId: Int) {
        send("refresh-client -B \(Self.reflowSubscriptionPrefix)\(paneId)")
    }

    /// Sends literal key bytes to a pane via tmux `send-keys -H` (hex-encoded),
    /// which is binary-safe and needs no shell quoting.
    func sendKeys(paneId: Int, data: Data) {
        guard !data.isEmpty else { return }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendInternal("send-keys -t %\(paneId) -H \(hex)", kind: .other)
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
    func pastePane(paneId: Int, text: String) {
        guard !text.isEmpty else { return }
        let buffer = "cmux-paste-\(paneId)"
        send("set-buffer -b \(buffer) \(RemoteTmuxHost.shellSingleQuoted(text))")
        send("paste-buffer -p -d -b \(buffer) -t %\(paneId)")
    }

    /// Detaches: terminating ssh kills the control client but leaves the remote
    /// tmux session alive for resume. Permanently ends the connection — no reconnect.
    func stop() {
        // Mark `.ended` FIRST so the deliberate teardown's stream-end is ignored and
        // never fires `onExit` or a reconnect: only a genuine remote end (a real
        // `%exit` or a session found gone on reconnect) notifies exit observers — so
        // detach / quit / window-close (preserve) and transport drops do not.
        connectionState = .ended
        reconnectTask?.cancel()
        reconnectTask = nil
        clientSizeDebounceTask?.cancel()
        clientSizeDebounceTask = nil
        attachRedrawKickTask?.cancel()
        attachRedrawKickTask = nil
        pendingAttachRedrawKick = false
        pendingFirstConnectSizeApply = false
        teardownProcessHandles()
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
        try? stdinHandle?.close()
        stdinHandle = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Internals

    private func sendInternal(_ command: String, kind: CommandKind) {
        guard let stdinHandle else { return }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            // The control pipe is dead (broken pipe). Crucially, do NOT enqueue
            // a pending command for a write that never reached tmux: the
            // %begin/%end correlation FIFO is positional, so one phantom entry
            // permanently misaligns every subsequent command result. Tear the
            // connection down instead and let observers reconnect.
            record("stdin-write-failed")
            handleWriteFailure()
            return
        }
        // Record only after the bytes are confirmed written, so the pending
        // FIFO stays in lock-step with what tmux actually received.
        pendingCommands.append(kind)
    }

    private func handleWriteFailure() {
        // A broken-pipe write means the transport dropped. Keep the mirror frozen
        // and reconnect (the remote tmux session survives an ssh client death)
        // rather than ending. `beginReconnecting` guards the source state.
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
        if let size = lastClientSize {
            send("refresh-client -C \(size.columns)x\(size.rows)")
        }
        // The re-applied size is usually a no-op (the server kept the window at our
        // size across the transport drop), so TUIs get no SIGWINCH — kick them so
        // they repaint over the re-seeded (possibly stale) frame. FIFO-safe: the
        // captures below are queued before the kick task's first push can run.
        scheduleAttachRedrawKickIfNeeded()
        for window in windowsByID.values {
            for paneId in window.paneIDsInOrder {
                observers.emitPaneOutput(paneId, Data("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8))
                // Reflow classification first so it lands before the (3-command)
                // capture seed; the flag only matters at the next resize, and the
                // earlier it arrives the smaller the window in which a resize hits
                // the conservative no-reflow default on a slow link.
                requestPaneReflow(paneId: paneId)
                subscribePaneReflow(paneId: paneId)
                capturePane(paneId: paneId)
                requestPanePath(paneId: paneId)
                subscribePanePath(paneId: paneId)
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
                // Resync the surfaces after a reconnect (a fresh client lost the
                // screen/subscriptions). DON'T reseed here: the attach's own
                // %begin/%end block hasn't been consumed yet, so queuing CORRELATED
                // commands now would misalign the %end correlation FIFO. Defer until
                // the first post-reconnect list-windows result (attach block drained,
                // windowsByID freshly repopulated). Skipped on the first connect (the
                // mirror seeds new tabs itself).
                if wasReconnecting {
                    pendingReconnectReseed = true
                } else {
                    // First connect: if a surface already computed its grid before we
                    // reached `.connected`, setClientSize stored it but dropped the
                    // send (no live stdin yet) and nothing re-applies it on first
                    // connect — so the remote would stay at ssh's 80×24. Do NOT send
                    // it from here: `.enter` is emitted BEFORE the attach's own
                    // %begin/%end block is consumed, and EVERY send (even kind
                    // `.other`) joins the positional result FIFO — a command queued
                    // now would be popped by the attach block and shift every later
                    // result one slot. Defer to the first list-windows result (attach
                    // block drained), exactly like the reconnect re-seed above.
                    pendingFirstConnectSizeApply = true
                }
            }
        case let .exit(reason):
            record("exit\(reason.map { " " + $0 } ?? "")")
            // A genuine remote end (session/server intentionally exited). No reconnect.
            guard connectionState != .ended else { return }
            connectionState = .ended
            reconnectTask?.cancel()
            reconnectTask = nil
            clientSizeDebounceTask?.cancel()
            clientSizeDebounceTask = nil
            attachRedrawKickTask?.cancel()
            attachRedrawKickTask = nil
            pendingAttachRedrawKick = false
            pendingFirstConnectSizeApply = false
            observers.notifyExit()
        case let .output(paneId, data):
            paneOutputByteCounts[paneId, default: 0] += data.count
            totalOutputBytes += data.count
            observers.emitPaneOutput(paneId, data)
        case let .sessionChanged(id, name):
            sessionId = id
            // Track the new name too: `sessionName` is the value reused for
            // attach/reconnect, so a remote rename must update it or the next
            // reconnect targets a stale session and is wrongly declared gone.
            sessionName = name
            record("session-changed $\(id)")
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
                for pane in closing.paneIDsInOrder { paneOutputByteCounts[pane] = nil }
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
            if name.hasPrefix(Self.cwdSubscriptionPrefix),
               let paneId = Int(name.dropFirst(Self.cwdSubscriptionPrefix.count)) {
                let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { observers.emitPaneCwd(paneId, path) }
            } else if name.hasPrefix(Self.reflowSubscriptionPrefix),
                      let paneId = Int(name.dropFirst(Self.reflowSubscriptionPrefix.count)) {
                // Reflow classification: "<alternate_on>|<pane_current_command>".
                classifyAndEmitReflow(paneId: paneId, rawValue: value, source: "sub")
            }
        case let .commandResult(_, lines, isError):
            // The first block on each control stream is the attach command's own —
            // consume it explicitly so it can never pop a queued command's slot off
            // the positional FIFO (see ``attachBlockDrained``).
            if !attachBlockDrained {
                attachBlockDrained = true
            } else {
                handleCommandResult(lines: lines, isError: isError)
            }
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
        guard !isError else { return }
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
                // Replace the topology, don't merge: a window closed remotely while we
                // were disconnected never delivers a %window-close (it lands on the dead
                // connection), so merging would leave it lingering in
                // windowsByID/activePaneByWindow/paneOutputByteCounts and
                // reseedAfterReconnect (which iterates windowsByID) would re-capture its
                // dead panes. Prune anything not in the fresh reply.
                let liveIDs = Set(order)
                windowsByID = next
                activePaneByWindow = activePaneByWindow.filter { liveIDs.contains($0.key) }
                let livePanes = Set(next.values.flatMap { $0.paneIDsInOrder })
                paneOutputByteCounts = paneOutputByteCounts.filter { livePanes.contains($0.key) }
                windowOrder = order
                observers.notifyTopologyChanged()
                // Now that the attach block is drained and the topology is fresh, run
                // the deferred reconnect re-seed (re-capture each pane). Queuing the
                // capture commands here keeps the result FIFO aligned.
                if pendingReconnectReseed {
                    pendingReconnectReseed = false
                    reseedAfterReconnect()
                }
                // First connect: apply the grid that was stored before `.enter` (the
                // attach block is drained here, so the send's result block correlates
                // cleanly — see `pendingFirstConnectSizeApply`). A surface that hasn't
                // computed a grid yet is covered by the debounced `setClientSize`.
                if pendingFirstConnectSizeApply {
                    pendingFirstConnectSizeApply = false
                    if let size = lastClientSize {
                        send("refresh-client -C \(size.columns)x\(size.rows)")
                    }
                }
                // First-connect coverage for the attach redraw kick: if the grid was
                // computed before `.enter`, no post-connect `setClientSize` may ever
                // fire (layout settled + same-size dedupe upstream), so the
                // debounced-send consumer never runs. This is the earliest point with
                // populated topology — and `windowsByID` was parsed from THIS
                // list-windows reply, generated before tmux processed the size apply
                // just queued above, so the at-target check sees the true pre-apply
                // geometry. No-op when the kick was already consumed (or when
                // reseedAfterReconnect just ran it).
                scheduleAttachRedrawKickIfNeeded()
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

    struct Snapshot: Sendable {
        let started: Bool
        let enterReceived: Bool
        let exited: Bool
        let sessionId: Int?
        let windowCount: Int
        let windowIDs: [Int]
        let paneOutputByteCounts: [Int: Int]
        let totalOutputBytes: Int
        let recentEvents: [String]
    }
}
