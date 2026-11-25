/// What an update relaunch would interrupt right now, as reported by the host app.
public struct UpdateRelaunchBlockers: Equatable, Sendable {
    /// Coding agents that are mid-turn. They finish on their own, so the gate waits for them.
    public var busyAgentCount: Int
    /// Other foreground commands in local terminals (a dev server, a build). They may never
    /// exit, so the gate holds the relaunch until the user chooses Install Now.
    public var runningCommandCount: Int
    /// Hardware input happened during the quiet window. Only automatic installs wait for it to
    /// clear: an install the user asked for is itself recent input.
    public var userInputActive: Bool
    /// The host cannot confirm the daemon/session mirror yet. Only automatic installs wait for
    /// it, and only for ``UpdateRelaunchGate/daemonUnavailableTimeout``.
    public var daemonStateUnavailable: Bool

    /// How long hardware input must be quiet before an automatic relaunch, unless the host sets
    /// its own (`updates.idleInstallQuietSeconds`).
    public static let quietInputPeriod: Duration = .seconds(60)

    /// Nothing would be interrupted.
    public static let empty = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 0)
    /// A conservative hold used before the host has a trustworthy daemon mirror.
    public static let daemonUnavailable = UpdateRelaunchBlockers(
        busyAgentCount: 0, runningCommandCount: 0, daemonStateUnavailable: true)

    /// Creates a blocker report.
    public init(busyAgentCount: Int, runningCommandCount: Int, userInputActive: Bool = false,
                daemonStateUnavailable: Bool = false) {
        self.busyAgentCount = busyAgentCount
        self.runningCommandCount = runningCommandCount
        self.userInputActive = userInputActive
        self.daemonStateUnavailable = daemonStateUnavailable
    }

    /// Whether the relaunch would interrupt nothing.
    public var isEmpty: Bool {
        busyAgentCount == 0 && runningCommandCount == 0 && !userInputActive && !daemonStateUnavailable
    }

    /// The blockers that hold an install the user asked for (a click, Install Now, Restart Now):
    /// the quiet-input and daemon-mirror holds apply only to automatic installs.
    public var forUserInstall: UpdateRelaunchBlockers {
        UpdateRelaunchBlockers(busyAgentCount: busyAgentCount, runningCommandCount: runningCommandCount)
    }
}

/// Holds a ready update's relaunch until nothing would be interrupted by it.
///
/// Automatic updates wait for busy agents to finish instead of interrupting a turn. Explicit
/// installs retain the bounded agent wait for a lifecycle state that never settles; agents
/// interrupted then are resumed by session restore. Other running commands are shown as a
/// warning and only the user's Install Now stops them. An automatic install also waits for a
/// short quiet input window, and for an unconfirmed daemon mirror up to
/// ``daemonUnavailableTimeout``; an install the user asked for never waits for either. While
/// waiting, the gate publishes ``UpdateState/installing(_:)`` carrying the current
/// ``UpdateRelaunchBlockers``; Install Now and Later are that state's existing
/// `retryTerminatingApplication` and `dismiss` actions.
@MainActor
final class UpdateRelaunchGate {
    /// How often a waiting gate re-reads the host's blockers.
    static let recheckInterval: Duration = .seconds(2)
    /// How long an explicit install waits for busy agents before relaunching anyway.
    static let agentTimeout: Duration = .seconds(30 * 60)
    /// How long an automatic install waits for a daemon mirror that stays unconfirmed before it
    /// relaunches on what it can see (the relaunch keeps the daemon and its sessions running).
    static let daemonUnavailableTimeout: Duration = .seconds(10 * 60)
    /// The longest an automatic install waits for anything; then it relaunches anyway and the
    /// daemon keeps every terminal and agent across it (`updates.idleInstallMaxWaitSeconds`).
    static let automaticWaitCap: Duration = .seconds(15 * 60)

    private let clock: any UpdateClock
    private let log: any UpdateLogging
    private let recheckInterval: Duration
    private let agentTimeout: Duration
    private let daemonUnavailableTimeout: Duration
    /// ``UpdateRelaunchGate/automaticWaitCap`` unless the host sets its own; read on each check.
    var automaticWaitCap: Duration = UpdateRelaunchGate.automaticWaitCap
    private var waitTask: Task<Void, Never>?
    private var pending: Pending?

    private final class Pending {
        /// Shown on the published waiting state ("Restart to Complete Update").
        let isAutoUpdate: Bool
        /// Nobody asked for this install: the idle-only holds apply.
        let automatic: Bool
        let relaunch: () -> Void
        let later: () -> Void
        var waited: Duration = .zero
        /// How long the daemon mirror has been unconfirmed without a break.
        var daemonUnavailableFor: Duration = .zero
        var published: UpdateRelaunchBlockers?

        init(isAutoUpdate: Bool, automatic: Bool, relaunch: @escaping () -> Void,
             later: @escaping () -> Void) {
            self.isAutoUpdate = isAutoUpdate
            self.automatic = automatic
            self.relaunch = relaunch
            self.later = later
        }
    }

    init(
        clock: any UpdateClock,
        log: any UpdateLogging,
        recheckInterval: Duration = UpdateRelaunchGate.recheckInterval,
        agentTimeout: Duration = UpdateRelaunchGate.agentTimeout,
        daemonUnavailableTimeout: Duration = UpdateRelaunchGate.daemonUnavailableTimeout
    ) {
        self.clock = clock
        self.log = log
        self.recheckInterval = recheckInterval
        self.agentTimeout = agentTimeout
        self.daemonUnavailableTimeout = daemonUnavailableTimeout
    }

    deinit {
        waitTask?.cancel()
    }

    /// Whether a relaunch is currently held.
    var isWaiting: Bool { pending != nil }

    /// Whether the relaunch may proceed given `blockers` after waiting `waited`, with the daemon
    /// mirror unconfirmed for the last `daemonUnavailableFor`. An install the user asked for
    /// (`automatic == false`) ignores the quiet-input and daemon-mirror holds; an automatic one
    /// stops waiting for anything once it has waited `automaticWaitCap`.
    nonisolated static func shouldRelaunch(
        _ blockers: UpdateRelaunchBlockers,
        automatic: Bool,
        waited: Duration,
        daemonUnavailableFor: Duration,
        agentTimeout: Duration,
        daemonUnavailableTimeout: Duration,
        automaticWaitCap: Duration
    ) -> Bool {
        guard automatic else {
            if blockers.runningCommandCount > 0 { return false }
            if blockers.busyAgentCount > 0 { return waited >= agentTimeout }
            return true
        }
        if waited >= automaticWaitCap { return true }
        if blockers.daemonStateUnavailable, daemonUnavailableFor < daemonUnavailableTimeout { return false }
        if blockers.runningCommandCount > 0 { return false }
        if blockers.userInputActive { return false }
        if blockers.busyAgentCount > 0 { return false }
        return true
    }

    /// Runs `relaunch` now if nothing would be interrupted, otherwise publishes a waiting
    /// state through `publish` and runs it once the blockers clear, the agent timeout
    /// elapses, or the user chooses Install Now. `automatic` marks an install nobody asked for
    /// (the idle policy); `isAutoUpdate` only labels the published waiting state. `later` runs
    /// instead if the user defers.
    /// Each hold runs at most one of `relaunch` or `later`: a new hold defers the old one,
    /// and ``cancel()`` (the update session ended) runs neither. `isShown` reports whether
    /// the published waiting state is still the visible one; once something else replaced it,
    /// the hold ends without touching the newer state.
    func hold(
        isAutoUpdate: Bool,
        automatic: Bool = false,
        blockers: @escaping @MainActor () -> UpdateRelaunchBlockers,
        isShown: @escaping @MainActor () -> Bool,
        publish: @escaping @MainActor (UpdateState) -> Void,
        relaunch: @escaping () -> Void,
        later: @escaping () -> Void
    ) {
        if let previous = pending {
            finish(previous, relaunching: false)
        }
        let request = Pending(isAutoUpdate: isAutoUpdate, automatic: automatic, relaunch: relaunch,
                              later: later)
        pending = request
        guard !evaluate(request, blockers: blockers(), publish: publish) else { return }
        let interval = recheckInterval
        waitTask = Task { @MainActor [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, self.pending === request else { return }
                guard isShown() else {
                    self.log.append("update relaunch gate: waiting state replaced; ending hold")
                    self.cancel()
                    return
                }
                let current = blockers()
                request.waited += interval
                request.daemonUnavailableFor = current.daemonStateUnavailable
                    ? request.daemonUnavailableFor + interval : .zero
                if self.evaluate(request, blockers: current, publish: publish) { return }
            }
        }
    }

    /// Returns `true` when the request finished (relaunched).
    private func evaluate(
        _ request: Pending,
        blockers reported: UpdateRelaunchBlockers,
        publish: @MainActor (UpdateState) -> Void
    ) -> Bool {
        let current = request.automatic ? reported : reported.forUserInstall
        if Self.shouldRelaunch(current, automatic: request.automatic, waited: request.waited,
                               daemonUnavailableFor: request.daemonUnavailableFor,
                               agentTimeout: agentTimeout,
                               daemonUnavailableTimeout: daemonUnavailableTimeout,
                               automaticWaitCap: automaticWaitCap) {
            if request.automatic, !current.isEmpty, request.waited >= automaticWaitCap {
                log.append("update relaunch gate: automatic install waited its cap; relaunching")
            } else if current.busyAgentCount > 0 {
                log.append("update relaunch gate timed out with \(current.busyAgentCount) busy agent(s)")
            }
            if current.daemonStateUnavailable {
                log.append("update relaunch gate: daemon mirror still unconfirmed; relaunching")
            }
            finish(request, relaunching: true)
            return true
        }
        guard request.published != current else { return false }
        if request.published == nil {
            log.append(
                "update relaunch held (agents=\(current.busyAgentCount), commands=\(current.runningCommandCount), input=\(current.userInputActive), daemon=\(!current.daemonStateUnavailable), automatic=\(request.automatic))"
            )
        }
        request.published = current
        publish(.installing(.init(
            isAutoUpdate: request.isAutoUpdate,
            retryTerminatingApplication: { [weak self, weak request] in
                guard let self, let request else { return }
                self.log.append("update relaunch gate: install now")
                self.finish(request, relaunching: true)
            },
            dismiss: { [weak self, weak request] in
                guard let self, let request else { return }
                self.log.append("update relaunch gate: later")
                self.finish(request, relaunching: false)
            },
            relaunchBlockers: current
        )))
        return false
    }

    /// Ends a held relaunch without running either action, because the update session that
    /// owned it ended (an error, a finished cycle, or a completed install).
    func cancel() {
        guard pending != nil else { return }
        pending = nil
        waitTask?.cancel()
        waitTask = nil
    }

    private func finish(_ request: Pending, relaunching: Bool) {
        guard pending === request else { return }
        pending = nil
        waitTask?.cancel()
        waitTask = nil
        if relaunching {
            request.relaunch()
        } else {
            request.later()
        }
    }
}
