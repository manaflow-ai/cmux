import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextWakeups
public import Observation
import os

/// The local daemon's recovery while it cannot be reached (cx-jniyz.1): the
/// launch window offers Retry Now and, once a plain `server ensure` failed or the
/// connected daemon stopped answering (``offersRestart``), Restart cmux-tui, with
/// why the start failed (``startFailure``: a full disk is told apart, restore fuzz
/// h2). A window that shows content offers it in a notice (`DaemonRecoveryNotice`).
/// Remote machines have no launcher, so they offer neither. An owner whose ensures
/// keep failing as a stuck owner makes them fail for a sustained window restarts
/// without the button (``UnresponsiveOwnerWatch``, once per owner process) unless
/// ``restartsUnresponsiveOwner`` says no.
@MainActor
@Observable
public final class DaemonRecovery {
    /// The last `server ensure` failed (``startFailure``: no daemon could be reached or
    /// started, whatever the cause), or the connected daemon leaves its heartbeat unanswered
    /// (``daemonNotAnswering``). Every failed start offers it, so the person always has a way
    /// out while no daemon runs (restore fuzz h2: a start that failed on a full disk offered
    /// nothing); `--replace-unresponsive` with no owner running only starts one.
    public private(set) var offersRestart = false
    /// Why the last `server ensure` failed; nil after one that worked.
    public private(set) var startFailure: DaemonStartFailure?
    /// The connected daemon leaves its heartbeat unanswered while its process is alive (stopped or wedged):
    /// its connection stays open and its requests keep waiting (P0 2026-10-30), and Restart is offered.
    public private(set) var daemonNotAnswering = false
    /// The `server ensure` a not-answering daemon's heartbeat started (``noteDaemonAnswering(_:)``); nil when none runs.
    @ObservationIgnored private var ownerProbe: Task<Void, Never>?
    /// A Restart runs (up to 20 s of probe and stop, then the new owner's start).
    public private(set) var isRestarting = false
    /// Why the last Restart did not work (the refusal code or error, for Copy
    /// Details); nil after Retry Now or a Restart that worked.
    public private(set) var restartFailure: String?
    /// When an unresponsive owner restarts by itself (tests shorten it before `attach`).
    @ObservationIgnored var unresponsivePolicy = UnresponsiveOwnerWatch.Policy.standard
    private nonisolated let restartsUnresponsive = Mutex<@Sendable () -> Bool>({ true })
    @ObservationIgnored private var launcher: DaemonLauncher?
    @ObservationIgnored private var watch: UnresponsiveOwnerWatch?
    @ObservationIgnored private var wake: RetryWake?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    public init() {}

    /// True once the local daemon's launcher is known (`DaemonService.start(launch:)`).
    public var canRetry: Bool { wake != nil }

    /// Whether an owner that stays unresponsive restarts without asking (default on). Read before
    /// each automatic restart, off the main actor; the App sets it to its Debug Settings toggle.
    public nonisolated var restartsUnresponsiveOwner: @Sendable () -> Bool {
        get { restartsUnresponsive.withLock { $0 } }
        set { restartsUnresponsive.withLock { $0 = newValue } }
    }

    /// Follows `launcher`'s ensure outcomes; `wake` is the service's retry wake.
    func attach(_ launcher: DaemonLauncher, wake: RetryWake) {
        self.launcher = launcher
        self.wake = wake
        // The button's restart without its confirm: the terminal hosts are separate processes,
        // so they outlive the stuck owner and the next owner adopts them.
        watch?.stop()
        let watch = UnresponsiveOwnerWatch(policy: unresponsivePolicy, isEnabled: { [weak self] in
            self?.restartsUnresponsiveOwner() ?? false
        }, replace: { [weak self] claim in
            await self?.restartUnresponsive(claim) ?? false
        })
        self.watch = watch
        launcher.ensureOutcome.follow(watch)
        let outcome = launcher.ensureOutcome
        outcome.observe { [weak self] in
            guard let self else { return }
            noteStart(outcome.failure)
        }
        noteStart(outcome.failure)
    }

    /// The connected daemon answers its heartbeat (true) or left one more ask unanswered while its connection stays
    /// open (false; ``DaemonConnection/observeAnswering(_:)``). While it does not answer, each unanswered ask runs one
    /// plain `server ensure` when none runs, so ``UnresponsiveOwnerWatch`` judges the owner exactly as it did when a
    /// missed heartbeat closed the connection and the reconnect ran the ensure: a stuck owner is still restarted (when
    /// ``restartsUnresponsiveOwner`` allows it) and Restart is offered, while the connection and its requests wait.
    func noteDaemonAnswering(_ answering: Bool) {
        if daemonNotAnswering == answering {
            daemonNotAnswering = !answering
            logger.notice("cmux-tui \(answering ? "answers again" : "is not answering; its connection stays open", privacy: .public)")
            updateOffer()
        }
        if answering {
            ownerProbe?.cancel()
            ownerProbe = nil
        } else {
            probeOwner()
        }
    }

    /// One `server ensure` for the watch, unless one runs already.
    private func probeOwner() {
        guard ownerProbe == nil, let launcher else { return }
        // task-owner: one ensure at a time (`ownerProbe`), bounded by the ensure's own deadlines; an answer or
        // `detach` cancels it. Off main: it awaits the ensure process; its one step on main clears `ownerProbe`.
        ownerProbe = Task { @concurrent [weak self] in
            await launcher.probeOwner()
            await self?.ownerProbeEnded()
        }
    }

    private func ownerProbeEnded() {
        ownerProbe = nil
    }

    /// The launcher's last ensure ended: `failure` nil when it worked.
    private func noteStart(_ failure: DaemonStartFailure?) {
        if startFailure != failure { startFailure = failure }
        // An ensure that worked (the owner recovered by itself) ends an earlier Restart's failure.
        if failure == nil { restartFailure = nil }
        updateOffer()
    }

    /// Restart is offered while the last ensure failed or the connected daemon does not answer, and a launcher is known.
    private func updateOffer() {
        let offers = launcher != nil && (startFailure != nil || daemonNotAnswering)
        if offersRestart != offers { offersRestart = offers }
    }

    /// Ends the automatic restart: the service shut its connection down (`shutdownConnection`), so
    /// nothing may start an owner again behind it. A later `attach` follows the launcher afresh.
    func detach() {
        watch?.stop()
        watch = nil
        ownerProbe?.cancel()
        ownerProbe = nil
    }

    /// The watch's restart: on the main actor, only while no Restart runs and the watch still
    /// claims it (the toggle on, the same owner still stuck), then the button's restart with no
    /// confirm. No suspension between the claim and `restart` setting ``isRestarting``.
    private func restartUnresponsive(_ claim: @Sendable () -> Bool) async -> Bool {
        guard launcher != nil, !isRestarting, claim() else { return false }
        return await restart(automatic: true)
    }

    /// Tries to connect now instead of at the next backoff step.
    public func retryNow() {
        restartFailure = nil
        wake?.fire()
    }

    /// Stops the unresponsive owner and starts a new one (`server ensure
    /// --replace-unresponsive`), then tries to connect at once. SIGTERM
    /// leaves the terminal hosts running and the new owner adopts them.
    /// `automatic`: the watch asked, not the button (for the log). True when it replaced.
    @discardableResult
    public func restart(automatic: Bool = false) async -> Bool {
        guard let launcher, !isRestarting else { return false }
        isRestarting = true
        restartFailure = nil
        let source = automatic ? "automatic" : "requested"
        var replaced = false
        do {
            let result = try await launcher.replaceUnresponsive()
            replaced = true
            logger.notice("cmux-tui restart (\(source, privacy: .public)): \(result.status, privacy: .public), pid \(result.pid)")
        } catch {
            restartFailure = String(describing: error)
            logger.error("cmux-tui restart (\(source, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
        isRestarting = false
        wake?.fire()
        return replaced
    }
}
