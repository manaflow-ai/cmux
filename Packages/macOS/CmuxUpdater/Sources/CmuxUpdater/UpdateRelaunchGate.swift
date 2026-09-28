/// What an update relaunch would interrupt right now, as reported by the host app.
public struct UpdateRelaunchBlockers: Equatable, Sendable {
    /// Coding agents that are mid-turn. They finish on their own, so an automatic install waits
    /// for them.
    public var busyAgentCount: Int
    /// Other foreground commands in local terminals (a dev server, a build). Relaunching would
    /// stop them for good, so an automatic install waits for them too.
    public var runningCommandCount: Int

    /// Nothing would be interrupted.
    public static let empty = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 0)

    /// Creates a blocker report.
    public init(busyAgentCount: Int, runningCommandCount: Int) {
        self.busyAgentCount = busyAgentCount
        self.runningCommandCount = runningCommandCount
    }

    /// Whether the relaunch would interrupt nothing.
    public var isEmpty: Bool {
        busyAgentCount == 0 && runningCommandCount == 0
    }
}

/// Holds an automatically downloaded update's relaunch until a quiet moment: nothing would be
/// interrupted and nobody has touched the keyboard or mouse for ``quietPeriod``.
///
/// Only automatic installs wait here. An explicit Install and Relaunch, Restart Now or Install
/// Now is the user's consent and relaunches right away (#15084). There is no timeout: an
/// automatic install never stops a busy agent or a running command. Until a quiet moment comes,
/// the pill offers Install Now, and quitting cmux still installs the update.
///
/// When the moment comes, the gate asks the host to prepare (a fresh session capture, so every
/// agent is saved with its resume binding), then checks again, because an agent can start a turn
/// or the user can come back while the capture runs. Only a check that still passes relaunches.
///
/// While waiting, the gate publishes ``UpdateState/installing(_:)`` carrying the current
/// ``UpdateRelaunchBlockers``; Install Now and Later are that state's existing
/// `retryTerminatingApplication` and `dismiss` actions.
@MainActor
final class UpdateRelaunchGate {
    /// How often a waiting gate re-reads the host's blockers and input idle time.
    static let recheckInterval: Duration = .seconds(2)
    /// How long the keyboard and mouse must be untouched before an automatic relaunch.
    static let quietPeriod: Duration = .seconds(60)

    private let clock: any UpdateClock
    private let log: any UpdateLogging
    private let recheckInterval: Duration
    private let quietPeriod: Duration
    private var waitTask: Task<Void, Never>?
    private var pending: Pending?

    /// What the gate reads from the host on every check.
    struct Readiness: Equatable {
        var blockers: UpdateRelaunchBlockers
        var idle: Duration
    }

    private final class Pending {
        let relaunch: () -> Void
        let later: () -> Void
        var published: UpdateRelaunchBlockers?
        var isPreparing = false
        var installNowRequested = false

        init(relaunch: @escaping () -> Void, later: @escaping () -> Void) {
            self.relaunch = relaunch
            self.later = later
        }
    }

    init(
        clock: any UpdateClock,
        log: any UpdateLogging,
        recheckInterval: Duration = UpdateRelaunchGate.recheckInterval,
        quietPeriod: Duration = UpdateRelaunchGate.quietPeriod
    ) {
        self.clock = clock
        self.log = log
        self.recheckInterval = recheckInterval
        self.quietPeriod = quietPeriod
    }

    deinit {
        waitTask?.cancel()
    }

    /// Whether a relaunch is currently held.
    var isWaiting: Bool { pending != nil }

    /// Whether an automatic relaunch may proceed now.
    nonisolated static func isQuietMoment(_ readiness: Readiness, quietPeriod: Duration) -> Bool {
        readiness.blockers.isEmpty && readiness.idle >= quietPeriod
    }

    /// Publishes a waiting state through `publish` and, at the next quiet moment, runs `prepare`
    /// and then `relaunch` if it is still quiet. Install Now runs `prepare` and `relaunch`
    /// without waiting; Later runs `later` instead. Each hold runs at most one of `relaunch` or
    /// `later`: a new hold defers the old one, and ``cancel()`` (the update session ended) runs
    /// neither. `isShown` reports whether the published waiting state is still the visible one;
    /// once something else replaced it, the hold ends without touching the newer state.
    func hold(
        readiness: @escaping @MainActor () -> Readiness,
        isShown: @escaping @MainActor () -> Bool,
        publish: @escaping @MainActor (UpdateState) -> Void,
        prepare: @escaping @MainActor () async -> Void,
        relaunch: @escaping () -> Void,
        later: @escaping () -> Void
    ) {
        if let previous = pending {
            finish(previous, relaunching: false)
        }
        let request = Pending(relaunch: relaunch, later: later)
        pending = request
        log.append("automatic update install waiting for a quiet moment")
        publishWaiting(request, blockers: readiness().blockers, publish: publish, prepare: prepare)
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
                let current = readiness()
                guard Self.isQuietMoment(current, quietPeriod: self.quietPeriod) else {
                    self.publishWaiting(request, blockers: current.blockers, publish: publish, prepare: prepare)
                    continue
                }
                self.log.append("update relaunch gate: quiet moment; preparing to relaunch")
                request.isPreparing = true
                await prepare()
                request.isPreparing = false
                guard self.pending === request else { return }
                // The capture takes a moment: an agent may have started a turn, or the user may
                // be back. Relaunch only if it is still quiet.
                let after = readiness()
                if request.installNowRequested || Self.isQuietMoment(after, quietPeriod: self.quietPeriod) {
                    self.log.append("update relaunch gate: relaunching")
                    self.finish(request, relaunching: true)
                    return
                }
                self.log.append(
                    "update relaunch gate: activity during prepare (agents=\(after.blockers.busyAgentCount), commands=\(after.blockers.runningCommandCount)); waiting again"
                )
                self.publishWaiting(request, blockers: after.blockers, publish: publish, prepare: prepare)
            }
        }
    }

    private func publishWaiting(
        _ request: Pending,
        blockers current: UpdateRelaunchBlockers,
        publish: @MainActor (UpdateState) -> Void,
        prepare: @escaping @MainActor () async -> Void
    ) {
        guard request.published != current else { return }
        request.published = current
        publish(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self, weak request] in
                guard let self, let request, self.pending === request else { return }
                self.log.append("update relaunch gate: install now")
                guard !request.isPreparing else {
                    // The capture for a quiet moment is already running; relaunch when it ends.
                    request.installNowRequested = true
                    return
                }
                self.waitTask?.cancel()
                self.waitTask = nil
                request.isPreparing = true
                Task { @MainActor [weak self] in
                    await prepare()
                    self?.finish(request, relaunching: true)
                }
            },
            dismiss: { [weak self, weak request] in
                guard let self, let request else { return }
                self.log.append("update relaunch gate: later")
                self.finish(request, relaunching: false)
            },
            relaunchBlockers: current
        )))
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
