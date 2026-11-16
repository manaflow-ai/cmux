import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
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
    /// The start keeps failing (``NoticePolicy``): cmux-tui is down until the person acts, so a window that shows
    /// content says so (`DaemonRecoveryNotice`). False while starts fail only once or twice, or only for a short
    /// while: a daemon that restarts (a version handoff, a crash, a missed heartbeat on a loaded Mac) is retried
    /// quietly.
    public private(set) var startFailurePersists = false
    /// When the failed starts of ``startFailurePersists`` began; nil after a start that worked.
    @ObservationIgnored private var failingSince: ContinuousClock.Instant?
    /// When failed starts count as cmux-tui being down (tests shorten it).
    @ObservationIgnored var noticePolicy = NoticePolicy.standard
    /// Now, for ``noticePolicy``'s window (tests move it).
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// The connected daemon leaves its heartbeat unanswered while its process is alive (stopped or wedged):
    /// its connection stays open and its requests keep waiting (P0 2026-10-30), and Restart is offered.
    public private(set) var daemonNotAnswering = false
    /// The `server ensure` a not-answering daemon's heartbeat started (``noteDaemonAnswering(_:)``); nil when none runs.
    @ObservationIgnored private var ownerProbe: Task<Void, Never>?
    /// The session owner is restoring while the app waits for it (``EnsureOutcome/restoring``), with
    /// `waitedMs` counted from the first report of this restore: a later ensure on the same owner reports
    /// from its own start, and the time shown never steps back. Nil once an ensure ends.
    public private(set) var restoring: RestoreProgressReport?
    /// ``restoring`` is set: changes only when a restore starts or ends, not at each progress line, so the sidebar's rows
    /// (stale while it restores) and the startup deadline (it waits a restore out) follow it without a redraw per line.
    public private(set) var isRestoring = false
    /// ``restoring`` in the person's words ("Restoring sessions… 4m 12s"); nil while none.
    public var restoringText: String? { restoring.map { RefusalStrings.restoringSessions(waitedMs: $0.waitedMs) } }
    /// When the restore ``restoring`` reports began, and its owner; nil after a start that worked.
    @ObservationIgnored private var restoreBegan: (pid: Int32?, at: Date)?
    /// A Restart runs (up to 20 s of probe and stop, then the new owner's start).
    public private(set) var isRestarting = false
    /// Why the last Restart did not work (the refusal code or error, for Copy
    /// Details); nil after Retry Now or a Restart that worked.
    public private(set) var restartFailure: String?
    /// ``restartFailure`` is of a Restart the person asked for (not the automatic one): it shows the notice at once.
    public private(set) var requestedRestartFailed = false
    /// When an unresponsive owner restarts by itself (tests shorten it before `attach`).
    @ObservationIgnored var unresponsivePolicy = UnresponsiveOwnerWatch.Policy.standard
    private nonisolated let restartsUnresponsive = Mutex<@Sendable () -> Bool>({ true })
    @ObservationIgnored private var launcher: DaemonLauncher?
    @ObservationIgnored private var watch: UnresponsiveOwnerWatch?
    @ObservationIgnored private var wake: RetryWake?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")
    /// App health holds replacements (``AppHealth/holdsReplace``: the owner is restoring and still
    /// makes progress): the watch's automatic restart waits; a person's Restart still runs.
    @ObservationIgnored public var holdsReplace: @Sendable () -> Bool = { false }

    /// When failed starts count as cmux-tui being down (``startFailurePersists``): a full disk at once, because only
    /// the person can free space; any other failure once at least ``failedStarts`` starts in a row failed over at
    /// least ``sustained``. The reconnect tries at least every 30 s (`RetryPolicy.localReconnect`), so a start that
    /// stays broken is told within about ``sustained`` plus one attempt.
    public struct NoticePolicy: Sendable, Equatable {
        public var failedStarts: Int
        public var sustained: Duration

        /// Three failed starts over two minutes: past a restart under heavy load (each failed ensure already
        /// waited 20 s of silence, or the owner's restore bound).
        public static let standard = NoticePolicy(failedStarts: 3, sustained: .seconds(120))

        public init(failedStarts: Int, sustained: Duration) {
            self.failedStarts = failedStarts
            self.sustained = sustained
        }
    }

    public init() {}

    /// True once the local daemon's launcher is known (`DaemonService.start(launch:)`).
    public var canRetry: Bool { wake != nil }

    /// Whether an owner that stays unresponsive restarts without asking (default on). Read before
    /// each automatic restart, off the main actor; the App sets it to its Debug Settings toggle.
    public nonisolated var restartsUnresponsiveOwner: @Sendable () -> Bool {
        get { restartsUnresponsive.load() }
        set { restartsUnresponsive.store(newValue) }
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
            noteStart(outcome.failure, failedInARow: outcome.failedInARow)
        }
        noteStart(outcome.failure, failedInARow: outcome.failedInARow)
        outcome.observeRestoring { [weak self] in self?.noteRestoring(outcome.restoring) }
        noteRestoring(outcome.restoring)
    }

    /// The running ensure's restore progress changed (nil: it ended).
    func noteRestoring(_ report: RestoreProgressReport?) {
        if isRestoring != (report != nil) { isRestoring = report != nil }
        guard var report else {
            if restoring != nil { restoring = nil }
            return
        }
        let began = report.updatedAt.addingTimeInterval(-Double(report.waitedMs) / 1000)
        if let earlier = restoreBegan, earlier.pid == report.pid {
            restoreBegan = (report.pid, min(earlier.at, began))
        } else {
            restoreBegan = (report.pid, began)
            let pid = report.pid.map { String($0) } ?? "unknown"
            logger.notice("cmux-tui is restoring sessions (pid \(pid, privacy: .public)); the app waits for it")
        }
        report.waitedMs = UInt64(max(0, report.updatedAt.timeIntervalSince(restoreBegan?.at ?? began)) * 1000)
        if restoring != report { restoring = report }
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

    /// The launcher's last ensure ended: `failure` nil when it worked; `failedInARow` ensures failed since one worked.
    func noteStart(_ failure: DaemonStartFailure?, failedInARow: Int) {
        if startFailure != failure { startFailure = failure }
        if failure == nil {
            failingSince = nil
            restoreBegan = nil
        } else if failingSince == nil {
            failingSince = now()
        }
        let persists = failure.map { failure in
            failure.isDiskFull || (failedInARow >= noticePolicy.failedStarts
                && failingSince.map { now() - $0 >= noticePolicy.sustained } == true)
        } ?? false
        if let failure {
            // Notice level, so it outlives the in-memory `.info` lines of the connection's reconnect (`log show` finds it).
            logger.notice("cmux-tui start failed (\(failedInARow, privacy: .public) in a row, \(persists ? "down" : "retrying quietly", privacy: .public)): \(failure.detail, privacy: .public)")
        }
        if startFailurePersists != persists { startFailurePersists = persists }
        // An ensure that worked (the owner recovered by itself) ends an earlier Restart's failure.
        if failure == nil {
            restartFailure = nil
            requestedRestartFailed = false
        }
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
        guard launcher != nil, !isRestarting else { return false }
        // Before the claim, which spends the watch's allowance for this owner.
        if holdsReplace() {
            logger.notice("cmux-tui automatic restart held: the owner is restoring and still makes progress")
            return false
        }
        guard claim() else { return false }
        return await restart(automatic: true)
    }

    /// Tries to connect now instead of at the next backoff step.
    public func retryNow() {
        restartFailure = nil
        requestedRestartFailed = false
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
        requestedRestartFailed = false
        let source = automatic ? "automatic" : "requested"
        var replaced = false
        do {
            // The automatic restart asks app health again just before the replace starts; a person's Restart runs regardless.
            let result = try await launcher.replaceUnresponsive(unlessHeld: automatic ? holdsReplace : nil)
            replaced = true
            logger.notice("cmux-tui restart (\(source, privacy: .public)): \(result.status, privacy: .public), pid \(result.pid)")
        } catch let refusal as DaemonLauncher.ReplaceRefusal where refusal.code == DaemonLauncher.ReplaceRefusal.heldCode {
            logger.notice("cmux-tui automatic restart held at its start: the owner is restoring and still makes progress")
        } catch {
            restartFailure = String(describing: error)
            requestedRestartFailed = !automatic
            logger.error("cmux-tui restart (\(source, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
        isRestarting = false
        wake?.fire()
        return replaced
    }
}
