import CmuxRemoteSession
import Foundation
import os

#if DEBUG
/// Environment overrides, in seconds, for the remote-tmux waits that decide how long a test
/// takes. DEBUG only, and read once.
///
/// Three waits set the floor on a test case's wall clock. A case whose stream never publishes a
/// topology pays the attach readiness barrier's 15 seconds. A case that closes a mirror on a
/// stream too wedged to answer pays the detach backstop's 3 seconds. A case that loses its
/// transport pays a 1 second first backoff and up to 10 seconds later on. None of the three has
/// an event that could shorten it — they exist precisely because the peer stopped answering — so
/// a suite of a few hundred cases costs hours unless a test can name a smaller number.
///
/// Unset means the shipped default, so a test that sets nothing behaves exactly like the
/// product. Each value is read the first time its timer is used, so a test has to set the
/// variable (launch environment, or `setenv` early in the process) before the first connection
/// is created.
///
/// A value has to parse as a finite number greater than zero. Anything else — empty, prose, `0`,
/// negative, `inf` — is ignored in favour of the default, because a mistyped value that turned a
/// barrier into a no-op would make every case pass without waiting for the thing under test.
enum RemoteTmuxDebugTimers {
    /// Override for the attach readiness barrier, `RemoteTmuxController.mirrorTopologyBarrierSeconds`
    /// (default 15).
    static let topologyBarrierSeconds = secondsFromEnvironment(
        "CMUX_REMOTE_TMUX_TOPOLOGY_BARRIER_SECONDS")
    /// Override for the deliberate-detach backstop,
    /// ``RemoteTmuxControlConnection/deliberateDetachBackstopSeconds`` (default 3).
    static let detachBackstopSeconds = secondsFromEnvironment(
        "CMUX_REMOTE_TMUX_DETACH_BACKSTOP_SECONDS")
    /// Override for the first reconnect backoff, `reconnectBaseDelaySeconds` (default 1).
    static let reconnectBaseSeconds = secondsFromEnvironment(
        "CMUX_REMOTE_TMUX_RECONNECT_BASE_SECONDS")
    /// Override for the reconnect backoff cap, `reconnectMaxDelaySeconds` (default 10).
    static let reconnectMaxSeconds = secondsFromEnvironment(
        "CMUX_REMOTE_TMUX_RECONNECT_MAX_SECONDS")

    private static func secondsFromEnvironment(_ name: String) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let seconds = Double(raw),
            seconds.isFinite,
            seconds > 0
        else { return nil }
        return seconds
    }
}
#endif

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
                // A connection that ends before publishing any window never had a mirror to
                // offer; fail its readiness waiters rather than leaving them to time out.
                resolveInitialTopology(ready: false)
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
    /// Per-pane capture/state transactions owning the snapshot-to-live cutover.
    var pendingPaneSeeds: [Int: [RemoteTmuxPendingPaneSeed]] = [:]
    /// Aggregate bytes retained by every in-flight pane seed on this connection.
    var pendingPaneSeedByteCount = 0
    let pendingPaneSeedByteLimit: Int
    /// The one queued or in-flight visible repaint seed allowed per pane.
    var pendingPaneVisibleRepaintSeedIDs: [Int: UUID] = [:]
    /// Panes that grew while a visible repaint seed was already in flight. One
    /// deferred repaint per pane bounds churn while preserving the latest repair.
    var deferredPaneVisibleRepaints: Set<Int> = []
    /// Reconnect seeds that must finish before consumers can resume resize work.
    var pendingReconnectSeedIDs: Set<UUID> = []
    /// Stable pane queue for reconnect snapshots. Only a small fixed number are
    /// captured concurrently so retained history is bounded independently of pane count.
    var pendingReconnectPaneIDs: [Int] = []
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
    /// In-flight raw-line queries (see ``queryWithTimeout(_:timeout:reconnectOnTimeout:)``),
    /// keyed by the token carried on their `.rawQuery` command. Flushed with nil on any
    /// stream reset so an awaiting coordinator never hangs.
    var rawQueryCompletions: [UUID: ([String]?) -> Void] = [:]
    var rawQueryTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// `true` when this connection is the multiplexer's shared per-host view stream
    /// (a hidden `cmux-view-*` session with other sessions' windows linked in), rather
    /// than a dedicated per-session connection. Enables the host-wide session-digest
    /// subscription and the extra topology notifications a shared stream needs.
    var isSharedViewStream = false
    /// Whether the ``sessionDigestSubscriptionName`` `refresh-client -B` is active.
    var sessionDigestSubscribed = false
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
    /// Bumped on every spawn. Readable across the type's extensions so a completion that
    /// outlived its process — a liveness probe answered after a respawn, say — can tell that its
    /// answer describes a stream that no longer exists. Writable only here.
    private(set) var processGeneration: UInt64 = 0
    var pendingCommands: [CommandKind] = []
    /// A `detach-client` cmux sent is still waiting for tmux's `%exit`. That exit is cmux's own
    /// doing, so it must not reach the exit observers as a session that ended remotely.
    private var awaitingDeliberateDetach = false
    private var deliberateDetachBackstop: DispatchWorkItem?
    /// How many times a `%exit` has been treated as a possible transport death and answered with a
    /// reattach. Reset by a successful attach, so it counts consecutive failures rather than a
    /// lifetime total.
    private var transportDeathReattachCount = 0
    /// Past this many consecutive transport-death reattaches, believe the `%exit`.
    static let maxTransportDeathReattempts = 3
    /// Whether a `%exit` from a persistent-remote transport is answered with a reattach.
    ///
    /// Always true in the product. It exists as a constant so the behaviour can be built out for a
    /// red/green comparison — the claim "without this, an externally detached mirror closes" is
    /// worth measuring rather than reading off the code path. Overridable only at compile time via
    /// `CMUX_NO_TRANSPORT_DEATH_REATTACH`, so no runtime surface ships.
    #if CMUX_NO_TRANSPORT_DEATH_REATTACH
    static let reattachOnPossibleTransportDeath = false
    #else
    static let reattachOnPossibleTransportDeath = true
    #endif

    /// Called from the publication path once an attach has produced windows.
    func clearTransportDeathReattachBudget() {
        guard transportDeathReattachCount > 0 else { return }
        record("transport-death-reattach-recovered after=\(transportDeathReattachCount)")
        transportDeathReattachCount = 0
    }
    var windowListRequestInFlight = false
    var windowListRequestDirty = false
    var windowReorderBatchFailed = false
    var windowReorderGeneration: UInt64 = 0
    var windowReorderRecoveryGeneration: UInt64?
    var windowReorderVerificationGeneration: UInt64?
    var windowReorderVerifications: [UInt64: (Bool) -> Void] = [:]
    private var connectionWaiters: [UUID: (Bool) -> Void] = [:]

    /// Whether this connection ever delivered a usable initial topology.
    ///
    /// Reaching control mode is not the same as having something to mirror. Measured against a
    /// real host: the stream sent the DCS intro, `%begin/%end`, `%session-changed`, and then
    /// `%exit` — no window ever arrived. `%enter` had already moved `connectionState` to
    /// `.connected`, so ``waitUntilConnected()`` returned true, the caller created a workspace,
    /// and the RPC reported success for a mirror that could never populate. The user saw an empty
    /// workspace with a local placeholder shell.
    ///
    /// Sticky on purpose: once a connection has published windows it stays `.ready`, so a later
    /// normal end (the session being killed, the last window closing) is not confused with an
    /// initial attach that never worked.
    enum InitialTopologyState: Equatable {
        case pending
        case ready
        case failed
    }

    private(set) var initialTopologyState: InitialTopologyState = .pending
    private var topologyWaiters: [UUID: (Bool) -> Void] = [:]
    /// `false` until the attach command's own `%begin`/`%end` block — always the
    /// FIRST block on each control stream, preceding every notification — has been
    /// consumed. That first block is matched explicitly (see the `.commandResult`
    /// dispatch) rather than by "FIFO happens to be empty", so a command that races
    /// in early (e.g. a debounced size send on a stalled link) can never have its
    /// result slot stolen by the attach block. Reset per spawn (each ssh re-attach
    /// produces a fresh attach block).
    private var attachBlockDrained = false
    /// How the initial attach opens the session. Reconnects always use `.attach`; see
    /// ``spawnProcess(mode:)``.
    let attachMode: RemoteTmuxControlAttachMode

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
    /// Periodic liveness probe for transports that reconnect internally (see
    /// ``checkLivenessAndRecoverIfStalled(completion:)``). Nil for ssh, which gets an EOF instead.
    private var livenessTask: Task<Void, Never>?
    /// Whether a liveness probe is still waiting for its answer. The next probe's due time is the
    /// previous one's deadline, so this is what turns "no answer" into a detected stall.
    var livenessProbeOutstanding = false
    /// How often to ask a self-reconnecting transport whether it is still carrying the protocol.
    /// Long enough that an ordinary reconnect finishes untouched, short enough that a wedged
    /// mirror is not left silently frozen.
    static var livenessProbeIntervalSeconds: UInt64 = 30
    /// Number of reconnect attempts since the last successful connect, driving the
    /// capped exponential backoff. Reset to 0 on a successful connect.
    private var reconnectAttemptCount = 0
    /// Set when a reconnect stopped because the host wants interactive authentication
    /// and a consumer was told. No retry is scheduled while this is true: the mirror is
    /// deliberately parked (frozen, not ended) until ``resumeAfterInteractiveAuth()``
    /// or ``stop()``.
    private var awaitingInteractiveAuth = false
    /// stderr text captured for the in-flight spawn, inspected when a reconnect
    /// attempt's process exits to tell "session genuinely gone" from "host still
    /// unreachable". Reset at the start of each spawn.
    private var stderrBuffer = ""
    private var preControlOutputBuffer = ""
    /// Set the first time the pre-control region looks like an unanswered prompt, and never unset for
    /// this process.
    ///
    /// The region is capped at ``maxStderrBytes`` and drops its oldest bytes, so recomputing the answer
    /// on demand meant a chatty transport could push the prompt out of the window and the observation
    /// would silently become false — a login that was seen and then forgotten. Reset per spawn along
    /// with the buffer it summarises.
    private var sawUnansweredCredentialPrompt = false
    /// Whether the bytes before control mode are an unanswered credential prompt: a transport waiting
    /// for a passcode it has no terminal to ask on.
    /// The pre-control region as the classifier sees it, capped, for diagnostics only. Distinguishes
    /// "nothing arrived" from "something arrived and did not match", which look identical from outside.
    var preControlObservationForDebug: String {
        let combined = preControlOutputBuffer + parser.unterminatedTail
        let flat = combined.replacingOccurrences(of: "\n", with: "\\n")
        return flat.count <= 200 ? flat : String(flat.suffix(200))
    }

    var isAwaitingCredentials: Bool {
        guard !enterReceived else { return false }
        if sawUnansweredCredentialPrompt { return true }
        // The tail is not in the buffer yet: a prompt is written without a newline, which is what makes
        // it a prompt, so it lives only in the parser until one arrives.
        return RemoteTmuxSSHTransport.indicatesUnansweredCredentialPrompt(parser.unterminatedTail)
    }

    /// Latches the observation while the bytes that carry it are still in the region.
    private func noteCredentialPromptIfSeen() {
        guard !enterReceived, !sawUnansweredCredentialPrompt else { return }
        if RemoteTmuxSSHTransport.indicatesUnansweredCredentialPrompt(
            preControlOutputBuffer + parser.unterminatedTail) {
            sawUnansweredCredentialPrompt = true
        }
    }
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
    /// DEBUG builds honor `CMUX_REMOTE_TMUX_RECONNECT_BASE_SECONDS` so a test that drives a
    /// transport death does not spend a second waiting for each retry; see ``RemoteTmuxDebugTimers``.
    private static let reconnectBaseDelaySeconds: Double = {
        #if DEBUG
        if let override = RemoteTmuxDebugTimers.reconnectBaseSeconds { return override }
        #endif
        return 1
    }()
    /// Cap on the reconnect backoff (seconds). Retries continue indefinitely at this
    /// interval until the network returns or the session is found to be gone.
    /// DEBUG builds honor `CMUX_REMOTE_TMUX_RECONNECT_MAX_SECONDS`, which matters for a case that
    /// takes several attempts: without lowering the cap the backoff reaches 10 seconds per retry.
    private static let reconnectMaxDelaySeconds: Double = {
        #if DEBUG
        if let override = RemoteTmuxDebugTimers.reconnectMaxSeconds { return override }
        #endif
        return 10
    }()
    /// How long ``detachThenStop(timeout:)`` waits for tmux's `%exit` before tearing the transport
    /// down anyway (seconds). DEBUG builds honor `CMUX_REMOTE_TMUX_DETACH_BACKSTOP_SECONDS`: a
    /// stream that cannot publish a topology also cannot confirm a detach, so every teardown in a
    /// failure case pays this wait in full.
    nonisolated static let deliberateDetachBackstopSeconds: TimeInterval = {
        #if DEBUG
        if let override = RemoteTmuxDebugTimers.detachBackstopSeconds { return override }
        #endif
        return 3
    }()
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

    /// How this connection is carried, derived from the host's transport unless a caller
    /// overrides it (which tests do, to assert argv without spawning anything).
    let transportProfile: RemoteTmuxTransportProfile

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        attachMode: RemoteTmuxControlAttachMode = .attach,
        transportProfile: RemoteTmuxTransportProfile? = nil,
        pendingPaneSeedByteLimit: Int = RemoteTmuxControlConnection.maximumPendingPaneSeedBytes
    ) {
        self.transportProfile = transportProfile
            ?? host.transport.profile(
                port: host.transportPort,
                terminalPath: host.transportTerminalPath,
                broker: host.transportBroker
            )
        self.host = host
        self.sessionName = sessionName
        self.attachMode = attachMode
        self.pendingPaneSeedByteLimit = max(0, pendingPaneSeedByteLimit)
    }

    /// Spawns the SSH `tmux -CC` process and begins streaming.
    func start() throws {
        guard !started else { return }
        try host.ensureControlSocketDirectory()
        // The initial connect honors the caller's mode; reconnects never create.
        try spawnProcess(mode: attachMode)
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
    /// - Parameter mode: the caller's mode only on the initial connect. Reconnect
    ///   attempts pass `.attach`, so a session killed during the outage fails the
    ///   re-attach (→ `.ended`) instead of being silently recreated.
    private func spawnProcess(mode: RemoteTmuxControlAttachMode) throws {
        // A fresh control stream cannot retain the prior parser or command FIFO.
        #if DEBUG
        cmuxDebugLog("remote.stream.reset pendingCommands=\(pendingCommands.count) mode=\(mode)")
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
        failPendingCommandTransactions()
        attachBlockDrained = false
        stderrBuffer = ""
        preControlOutputBuffer = ""
        sawUnansweredCredentialPrompt = false
        enterReceived = false

        // The remote command has to fit one canonical line, and this is the only place every
        // caller passes through.
        //
        // The socket boundary already refuses an over-long session name, but only on
        // `remote.tmux.attach`. The CLI drives `remote.tmux.mirror` and `remote.tmux.window`,
        // whose names come from discovery rather than from a parameter, so they never reach that
        // check — a real session with a long name, mirrored over a transport that types its
        // command, produced an attach that timed out with nothing to explain it. Checking here
        // covers every entrypoint by construction instead of once per RPC.
        if let overrun = transportProfile.commandLengthOverrun(
            sessionName: sessionName, mode: mode
        ) {
            let detail = "remote command is \(overrun.actual) bytes, over this transport's "
                + "\(overrun.budget)-byte limit; the remote shell would never receive it"
            record("transport-command-too-long")
            stderrBuffer.append(detail + "\n")
            // Throws rather than reporting an exit, and the difference is the whole point.
            //
            // This runs inside `start()`, before the caller has registered anything: `attach` adds
            // only `onSessionChanged` when it caches the connection, and the mirror's `onExit`
            // arrives later still. An earlier version ended the connection here and returned
            // normally, so `notifyExit()` fired with nobody listening, `started` was set, `attach`
            // cached the connection despite its "insert only after a successful launch" contract,
            // and `mirrorSession` reported success — leaving a permanently dead mirror workspace
            // with no error surfaced anywhere. On the multiplexer path the same call fired
            // re-entrantly, because `RemoteTmuxViewConnection` registers observers before `start()`.
            //
            // Throwing uses the failure route both callers already handle: nothing is cached, and
            // the error reaches the user.
            throw RemoteTmuxError.launchFailed(detail)
        }

        let proc = Process()
        let transportExecutable = transportProfile.executablePath()
        // The last gate before this string becomes a process. Everything upstream validates its own
        // inputs, but a broker reaches here from configuration rather than from the socket, and this
        // is the only point that sees what is actually about to run. Absolute path, no hidden
        // characters, and it has to exist: a relative name would be resolved against the app's PATH,
        // which for a GUI app is not the user's, and the failure then looks like an unreachable host
        // instead of a bad path.
        guard RemoteTmuxBrokerRegistry.isAcceptableExecutable(
            transportExecutable,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else {
            let detail = "refusing to launch '\(transportExecutable)': a transport executable must be"
                + " an absolute path to an existing executable file"
            record("transport-executable-rejected")
            stderrBuffer.append(detail + "\n")
            throw RemoteTmuxError.launchFailed(detail)
        }
        let transportArgv = transportProfile.controlStreamArgv(
            host: host,
            sessionName: sessionName,
            mode: mode
        )
        if transportProfile.requiresPseudoTerminal {
            // Not because the transport is silent on pipes — it is not, measured — but because
            // without usable terminal modes the client cannot go raw and the same stream arrives
            // far larger, padded with full-screen redraws. See requiresPseudoTerminal.
            record("transport-pty")
            proc.executableURL = URL(fileURLWithPath: RemoteTmuxPseudoTerminal.allocatorPath)
            proc.arguments = RemoteTmuxPseudoTerminal.wrap(
                executable: transportExecutable, arguments: transportArgv
            )
        } else {
            proc.executableURL = URL(fileURLWithPath: transportExecutable)
            proc.arguments = transportArgv
        }
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

    /// Suspends until this connection has published a usable initial topology, or until it is
    /// clear it never will. Callers that create a workspace for a mirror should await this rather
    /// than ``waitUntilConnected()``, which only proves the stream reached control mode.
    func waitUntilInitialTopology() async -> Bool {
        switch initialTopologyState {
        case .ready: return true
        case .failed: return false
        case .pending: break
        }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch initialTopologyState {
                case .ready:
                    continuation.resume(returning: true)
                    return
                case .failed:
                    continuation.resume(returning: false)
                    return
                case .pending:
                    break
                }
                topologyWaiters[token] = { ready in
                    continuation.resume(returning: ready)
                }
                if Task.isCancelled {
                    finishTopologyWaiter(token, ready: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishTopologyWaiter(token, ready: false)
            }
        }
    }

    /// How many callers are currently suspended on the readiness barrier.
    ///
    /// Exists so a test can wait for a waiter to be genuinely registered instead of sleeping and
    /// hoping: resolving before the waiter arrives makes the barrier answer from its already-resolved
    /// shortcut, so the pending path under test is never exercised and the assertion passes anyway.
    var initialTopologyWaiterCount: Int { topologyWaiters.count }

    /// Moves the sticky readiness state once, and releases anyone waiting on it.
    func resolveInitialTopology(ready: Bool) {
        guard initialTopologyState == .pending else { return }
        initialTopologyState = ready ? .ready : .failed
        record(ready ? "initial-topology-ready" : "initial-topology-failed")
        let waiters = Array(topologyWaiters.values)
        topologyWaiters.removeAll()
        for waiter in waiters { waiter(ready) }
    }

    private func finishTopologyWaiter(_ token: UUID, ready: Bool) {
        topologyWaiters.removeValue(forKey: token)?(ready)
    }

    /// Asks tmux to drop this control client, then tears the transport down once it confirms.
    ///
    /// ``stop()`` alone is a complete detach only when killing the local client closes the pty
    /// tmux is attached to. A transport whose remote half outlives its client
    /// (``RemoteTmuxTransportProfile/remoteHalfSurvivesLocalExit``) leaves the client attached
    /// forever, so the session collects one stale client per closed mirror.
    ///
    /// The wait is on tmux's own `%exit`, which is the confirmation that the client is gone.
    /// `timeout` is only a backstop for a stream that has already stopped answering; without one a
    /// wedged stream would keep the transport alive for good.
    func detachThenStop(timeout: TimeInterval = RemoteTmuxControlConnection.deliberateDetachBackstopSeconds) {
        guard transportProfile.remoteHalfSurvivesLocalExit,
              connectionState == .connected,
              sendInternal("detach-client", kind: .other) else {
            stop()
            return
        }
        record("detach-client-sent")
        awaitingDeliberateDetach = true
        // Strong on purpose. Callers reach this through `removeCachedConnection(forKey:)?.detachThenStop()`,
        // which drops the last reference in the same expression, so a weak capture could leave nobody
        // alive to receive tmux's `%exit` or to run this backstop — the detach would then depend
        // entirely on the enqueued bytes escaping a deallocating object. The queue holds this item for
        // at most `timeout`, and `stop()` cancels it, so the retain is bounded either way.
        let backstop = DispatchWorkItem {
            guard self.awaitingDeliberateDetach else { return }
            self.record("detach-client-unconfirmed")
            self.stop()
        }
        deliberateDetachBackstop = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: backstop)
    }

    /// Detaches: terminating ssh kills the control client but leaves the remote
    /// tmux session alive for resume. Permanently ends the connection — no reconnect.
    func stop() {
        awaitingDeliberateDetach = false
        deliberateDetachBackstop?.cancel()
        deliberateDetachBackstop = nil
        // Mark `.ended` FIRST so the deliberate teardown's stream-end is ignored and
        // never fires `onExit` or a reconnect: only a genuine remote end (a real
        // `%exit` or a session found gone on reconnect) notifies exit observers — so
        // detach / quit / window-close (preserve) and transport drops do not.
        connectionState = .ended
        awaitingInteractiveAuth = false
        cancelScheduledWork()
        teardownProcessHandles()
    }

    /// Cancels every scheduled follow-up (reconnect, debounced size sends, redraw
    /// kick) and the deferred post-attach work. Shared by deliberate teardown
    /// (``stop()``) and a genuine remote end (`%exit`).
    private func cancelScheduledWork() {
        failPendingCommandTransactions()
        reconnectTask?.cancel()
        reconnectTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        livenessProbeOutstanding = false
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

    /// Enqueues one tmux command queue while retaining one FIFO correlation
    /// entry for each semicolon-delimited command result.
    @discardableResult
    func sendCommandQueueInternal(_ commands: [String], kinds: [CommandKind]) -> Bool {
        guard !commands.isEmpty,
              commands.count == kinds.count,
              commands.allSatisfy({ !$0.contains("\n") }) else { return false }
        guard connectionState == .connected, let stdinWriter else { return false }
        guard let data = (commands.joined(separator: " ; ") + "\n").data(using: .utf8)
        else { return false }
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

    /// Feeds stream bytes through this connection's own parser.
    ///
    /// Internal rather than private so a test can drive the real path: the pre-control credential
    /// check reads the parser's unterminated tail, and a test that brings its own parser would not
    /// exercise it.
    func ingest(_ data: Data) {
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
            // The control stream died without `%exit`. What that means depends on who owns
            // reconnection: for ssh it is a transport loss cmux recovers from, but a
            // transport that reconnects internally does not end for a network drop, so its
            // exit is the session genuinely ending.
            // A transport that could not start will not start on the next try either, and
            // retrying hides the reason: end-of-stream no longer implies the session is over, so
            // without this the mirror waits out the attach timeout with nothing to explain it.
            if RemoteTmuxSSHTransport.indicatesUnrecoverableTransportFailure(stderrBuffer) {
                record("stream-end-unrecoverable")
                connectionState = .ended
                cancelScheduledWork()
                teardownProcessHandles()
                observers.notifyExit()
                return
            }
            switch RemoteTmuxStreamEndDisposition.forStreamEnd(hasReachedControlMode: enterReceived) {
            case .reconnect:
                // Keep the mirror frozen and reconnect.
                beginReconnecting()
            case .sessionOver:
                // Either the session ended, or the transport never started — both are terminal, and
                // both must report rather than retry.
                record(enterReceived ? "stream-end-session-over" : "stream-end-before-connect")
                connectionState = .ended
                cancelScheduledWork()
                teardownProcessHandles()
                observers.notifyExit()
            }
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
            // Classify into four outcomes, not two. A session/server found gone is a genuine end.
            // A transport that cannot run at all is equally terminal, and looping on it burns the
            // backoff forever while hiding the reason. A host asking for interactive authentication
            // is NOT transient: the reconnect runs `BatchMode=yes` on pipes with no tty, so no
            // number of retries can satisfy a password / MFA / FIDO touch — retrying forever leaves
            // the mirror frozen with nothing on screen to explain why. Everything else (unreachable,
            // refused) stays transient and keeps retrying.
            let disposition = RemoteTmuxReconnectDisposition.classify(
                stderr: stderrBuffer,
                preControlOutput: preControlOutputBuffer,
                decoding: decoding
            )
            let unrecoverable = RemoteTmuxSSHTransport.indicatesUnrecoverableTransportFailure(stderrBuffer)
            teardownProcessHandles()
            if disposition == .sessionGone || unrecoverable {
                if unrecoverable { record("reconnect-unrecoverable") }
                record("reconnect-session-gone")
                connectionState = .ended
                reconnectTask?.cancel()
                reconnectTask = nil
                observers.notifyExit()
            } else if disposition == .authRequired {
                // Stop the pointless retry loop and hand the user a login. The state
                // stays `.reconnecting` (the mirror is frozen, not dead) so the
                // session and every mirrored workspace survive the outage; a consumer
                // runs the argv under a tty and calls `resumeAfterInteractiveAuth()`.
                record("reconnect-auth-required")
                reconnectTask?.cancel()
                reconnectTask = nil
                awaitingInteractiveAuth = true
                let handled = observers.notifyAuthRequired(sshArgv: host.interactiveAuthInvocation())
                if !handled {
                    // Nobody is listening, so no login can arrive. Falling back to the
                    // backoff loop is strictly better than freezing forever: the host
                    // may become reachable without auth (a warm ControlMaster opened
                    // elsewhere), and the retry keeps that recovery possible.
                    record("reconnect-auth-required-unhandled")
                    awaitingInteractiveAuth = false
                    scheduleReconnectAttempt()
                }
            } else {
                scheduleReconnectAttempt()
            }
        }
    }

    // MARK: - Reconnect

    /// Starts the stall monitor for a transport that owns its own reconnection.
    ///
    /// ssh is deliberately excluded: its stream ends on transport loss, `handleStreamEnd` already
    /// recovers from that, and probing an idle ssh stream would add traffic and a failure mode
    /// where today there is none.
    private func startLivenessMonitorIfNeeded() {
        guard transportProfile.reconnectsInternally else { return }
        livenessTask?.cancel()
        let interval = Self.livenessProbeIntervalSeconds
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await MainActor.run { self.checkLivenessAndRecoverIfStalled() }
            }
        }
    }

    /// Freezes the mirror and reconnects after an unusable control stream.
    /// - Parameter preservingBackoff: keeps the current attempt count, so successive failures space
    ///   themselves out instead of each starting from the base delay. Set when the reason for
    ///   reconnecting is one that can repeat immediately — a `%exit` caused by the transport dying
    ///   arrives within a second of every attach, and resetting the backoff there turned recovery
    ///   into a tight loop against a tunnel that can demand interactive auth on each new connection.
    func beginReconnecting(preservingBackoff: Bool = false) {
        guard connectionState == .connected || connectionState == .connecting else { return }
        record("reconnecting\(preservingBackoff ? " preserving-backoff attempt=\(reconnectAttemptCount)" : "")")
        // The stream is dead: a close decision awaiting an activity query must
        // not hang for the whole backoff window — fail it onto the cache now.
        failPendingCommandTransactions()
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
        // A `refresh-client -B` subscription belongs to the client too, so the
        // session digest dies with it. The reconnect's attach drain calls
        // `subscribeSessionDigest()` again, and it returns early unless this flag is
        // cleared here — leaving the shared view blind to session create/kill/rename.
        sessionDigestSubscribed = false
        pendingPostAttachAction = nil
        teardownProcessHandles()
        if !preservingBackoff { reconnectAttemptCount = 0 }
        awaitingInteractiveAuth = false
        connectionState = .reconnecting
        scheduleReconnectAttempt()
    }

    /// Resumes reconnecting after the user completed an interactive login.
    ///
    /// Call this once the argv handed to `onAuthRequired` has exited successfully, so
    /// the shared ControlMaster is open and a pipe-backed re-attach can now
    /// authenticate over it. Retries start immediately (no backoff wait): the reason
    /// the previous attempt failed is gone, so making the user wait out a stale
    /// backoff would only look broken. Idempotent, and a no-op unless the connection
    /// is actually parked, so a duplicate callback cannot spawn a second retry chain.
    func resumeAfterInteractiveAuth() {
        guard awaitingInteractiveAuth, connectionState == .reconnecting else { return }
        record("resume-after-interactive-auth")
        awaitingInteractiveAuth = false
        reconnectAttemptCount = 0
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

    /// Re-spawns the ssh control client for a reconnect attempt. Always `.attach` so a
    /// session killed during the outage fails the re-attach (→ classified `.ended`)
    /// instead of being silently recreated empty — including for the hidden view
    /// session, whose initial attach may have created it.
    /// A spawn failure (e.g. control-socket dir) backs off and retries; the spawn's
    /// success/failure is observed via `.enter` (connected) or `handleStreamEnd`.
    private func attemptReconnectSpawn() {
        record("reconnect-attempt")
        do {
            try spawnProcess(mode: .attach)
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
                startLivenessMonitorIfNeeded()
                // Arm the one-shot attach redraw kick: if the upcoming size apply is
                // a no-op (window already at our size), a running TUI gets no SIGWINCH
                // and would keep showing its stale pre-attach frame. Consumed by the
                // first size apply (debounced send, reconnect re-seed, or the
                // first-connect list-windows result).
                //
                // Only a first attach needs it. A reconnect keeps the existing tmux grid and
                // replaces the mirror with an authoritative full-history seed; kicking after that
                // seed would shrink the local primary grid, move its first visible row into
                // scrollback, then paint that row again on restore.
                pendingAttachRedrawKick = !wasReconnecting
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
            // tmux confirming the `detach-client` cmux asked for. The client is gone, so the
            // transport can go now — and this is not a remote end, so no exit observers.
            if awaitingDeliberateDetach {
                record("detach-client-confirmed")
                stop()
                return
            }
            guard connectionState != .ended else { return }
            // A transport whose remote half outlives its client can take the tmux client down with
            // it, and the session survives. Measured over an et transport through a tunnel: control
            // mode came up, 845 ms later the tunnel's socket closed, the et client's reconnect was
            // answered INVALID_KEY so it shut down, and the closing remote pty made tmux emit this
            // `%exit` — for a session that `tmux ls` still listed. Trusting `%exit` alone there
            // closed a live session's mirror and told the user the host was unreachable.
            //
            // So ask instead of assuming, the same way stream EOF already does: reattach, and let
            // the attach report whether the session is really gone. A reconnect never creates one
            // (see `spawnProcess`), so a genuinely dead session cannot come back as an empty one.
            //
            // Bounded, because a tunnel that always dies would otherwise reattach forever:
            // `beginReconnecting` resets the backoff counter, so without a cap here repeated
            // transport deaths would retry at the base delay indefinitely.
            if Self.reattachOnPossibleTransportDeath,
               transportProfile.remoteHalfSurvivesLocalExit,
               enterReceived,
               transportDeathReattachCount < Self.maxTransportDeathReattempts {
                transportDeathReattachCount += 1
                record("exit-may-be-transport-death reattach=\(transportDeathReattachCount)")
                beginReconnecting(preservingBackoff: true)
                return
            }
            // A genuine remote end (session/server intentionally exited). No reconnect.
            connectionState = .ended
            cancelScheduledWork()
            observers.notifyExit()
        case let .output(paneId, data):
            paneOutputByteCounts[paneId, default: 0] += data.count
            totalOutputBytes += data.count
            routePaneOutput(paneId: paneId, data: data)
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
                    discardPendingPaneSeeds(paneId: pane)
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
            } else if name == Self.sessionDigestSubscriptionName, isSharedViewStream {
                // Host-wide session create/kill/rename digest. GA per-session clients
                // also see other sessions here, so only the shared view stream uses it
                // to re-list and rebuild multiplexed mirrors (coalesced by the view
                // coordinator's in-flight reconcile guard).
                observers.notifyTopologyChanged()
            }
        case let .commandResult(_, lines, isError):
            // The first block on each control stream is the attach command's own —
            // consume it explicitly so it can never pop a queued command's slot off
            // the positional FIFO (see ``attachBlockDrained``).
            if !attachBlockDrained {
                attachBlockDrained = true
                if isSharedViewStream { subscribeSessionDigest() }
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
            // Both phases, not just reconnecting. A first attach needs this as much as a reconnect:
            // a transport that authenticates itself never reports a failure, it prints a prompt and
            // waits, and that prompt is the only evidence it produces. Gated to `.reconnecting` the
            // buffer was always empty on a first attach, so a credential check against it could not
            // be true wherever it was placed — measured, after three fixes that never fired.
            if connectionState == .reconnecting || connectionState == .connecting, !enterReceived {
                preControlOutputBuffer += line + "\n"
                noteCredentialPromptIfSeen()
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
