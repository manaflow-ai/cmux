/// What an update relaunch would interrupt right now, as reported by the host app.
public struct UpdateRelaunchBlockers: Equatable, Sendable {
    /// Coding agents that are mid-turn. They finish on their own, so the gate waits for them.
    public var busyAgentCount: Int
    /// Other foreground commands in local terminals (a dev server, a build). They may never
    /// exit, so the gate holds the relaunch until the user chooses Install Now.
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

/// Holds a ready update's relaunch until nothing would be interrupted by it.
///
/// Busy agents are waited out, bounded by ``agentTimeout`` so a lifecycle state that never
/// settles cannot hold an update forever; agents interrupted then are resumed by session
/// restore. Other running commands are shown as a warning and only the user's Install Now
/// stops them. While waiting, the gate publishes ``UpdateState/installing(_:)`` carrying the
/// current ``UpdateRelaunchBlockers``; Install Now and Later are that state's existing
/// `retryTerminatingApplication` and `dismiss` actions.
@MainActor
final class UpdateRelaunchGate {
    /// How often a waiting gate re-reads the host's blockers.
    static let recheckInterval: Duration = .seconds(2)
    /// How long the gate waits for busy agents before relaunching anyway.
    static let agentTimeout: Duration = .seconds(30 * 60)

    private let clock: any UpdateClock
    private let log: any UpdateLogging
    private let recheckInterval: Duration
    private let agentTimeout: Duration
    private var waitTask: Task<Void, Never>?
    private var pending: Pending?

    private final class Pending {
        let isAutoUpdate: Bool
        let relaunch: () -> Void
        let later: () -> Void
        var waited: Duration = .zero
        var published: UpdateRelaunchBlockers?

        init(isAutoUpdate: Bool, relaunch: @escaping () -> Void, later: @escaping () -> Void) {
            self.isAutoUpdate = isAutoUpdate
            self.relaunch = relaunch
            self.later = later
        }
    }

    init(
        clock: any UpdateClock,
        log: any UpdateLogging,
        recheckInterval: Duration = UpdateRelaunchGate.recheckInterval,
        agentTimeout: Duration = UpdateRelaunchGate.agentTimeout
    ) {
        self.clock = clock
        self.log = log
        self.recheckInterval = recheckInterval
        self.agentTimeout = agentTimeout
    }

    deinit {
        waitTask?.cancel()
    }

    /// Whether a relaunch is currently held.
    var isWaiting: Bool { pending != nil }

    /// Whether the relaunch may proceed given `blockers` after waiting `waited`.
    nonisolated static func shouldRelaunch(
        _ blockers: UpdateRelaunchBlockers,
        waited: Duration,
        agentTimeout: Duration
    ) -> Bool {
        if blockers.runningCommandCount > 0 { return false }
        if blockers.busyAgentCount > 0 { return waited >= agentTimeout }
        return true
    }

    /// Runs `relaunch` now if nothing would be interrupted, otherwise publishes a waiting
    /// state through `publish` and runs it once the blockers clear, the agent timeout
    /// elapses, or the user chooses Install Now. `later` runs instead if the user defers.
    /// Each hold runs at most one of `relaunch` or `later`: a new hold defers the old one,
    /// and ``cancel()`` (the update session ended) runs neither. `isShown` reports whether
    /// the published waiting state is still the visible one; once something else replaced it,
    /// the hold ends without touching the newer state.
    func hold(
        isAutoUpdate: Bool,
        blockers: @escaping @MainActor () -> UpdateRelaunchBlockers,
        isShown: @escaping @MainActor () -> Bool,
        publish: @escaping @MainActor (UpdateState) -> Void,
        relaunch: @escaping () -> Void,
        later: @escaping () -> Void
    ) {
        if let previous = pending {
            finish(previous, relaunching: false)
        }
        let request = Pending(isAutoUpdate: isAutoUpdate, relaunch: relaunch, later: later)
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
                request.waited += interval
                if self.evaluate(request, blockers: blockers(), publish: publish) { return }
            }
        }
    }

    /// Returns `true` when the request finished (relaunched).
    private func evaluate(
        _ request: Pending,
        blockers current: UpdateRelaunchBlockers,
        publish: @MainActor (UpdateState) -> Void
    ) -> Bool {
        if Self.shouldRelaunch(current, waited: request.waited, agentTimeout: agentTimeout) {
            if current.busyAgentCount > 0 {
                log.append("update relaunch gate timed out with \(current.busyAgentCount) busy agent(s)")
            }
            finish(request, relaunching: true)
            return true
        }
        guard request.published != current else { return false }
        if request.published == nil {
            log.append(
                "update relaunch held (agents=\(current.busyAgentCount), commands=\(current.runningCommandCount))"
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
