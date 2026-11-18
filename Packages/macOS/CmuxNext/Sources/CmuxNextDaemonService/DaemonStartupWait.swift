public import CmuxNextActions
import CmuxNextCompat
import CmuxNextWakeups

/// What a person does while this Mac's cmux is still starting waits and runs once it is ready, in the
/// order they did it, instead of a "Try again in a moment" refusal (Leo, 2026-11-17: "remove bullshit
/// ceremony + bullshit text + bullshit belt and suspenders"). Two reasons wait: the local service has
/// not answered yet (``RefusalStrings/daemonConnecting``), and the home session's spaces and groups
/// are still loading (``RefusalStrings/personalStateLoading``). A run waits when its action is off for
/// one of them (``ActionRecovery``, for a key, a menu or the palette) or its handler refused with one
/// (``ActionRegistry/refusalDeferrals``). Nothing shows while it waits.
///
/// Stop condition: the waiting runs are dropped, with one line, when the service fails to start or
/// personal state can no longer load, or after ``PendingOpenPatience/limit`` (the restore queue's
/// patience, ``PendingSessionOpen``). The CLI, MCP, scripts and pages are refused with the reason as
/// before; they can retry.
@MainActor
public final class DaemonStartupWait {
    /// Where a held run stands now.
    nonisolated enum Readiness: Equatable, Sendable { case waiting, ready, failed }

    private struct Held {
        let reason: String
        let run: @MainActor () -> Void
    }

    /// Where the wait for `reason` stands, read through Observation.
    private let readiness: @MainActor @Sendable (String) -> Readiness
    /// The registry it is bound into: a dropped wait is refused there once (the App shows a loud refusal in the active window).
    private weak var registry: ActionRegistry?
    private var held: [Held] = []
    private var watch: Task<Void, Never>?
    private let expiry: DemandTimer
    /// How long runs wait before they are dropped.
    private let patience: Duration
    /// True while held runs are performed again: a run still refused then shows its refusal.
    private var replaying = false

    /// `daemon`: this Mac's service; its home store's personal state is the spaces and groups.
    public convenience init(daemon: DaemonService) {
        self.init(readiness: { reason in
            Self.state(of: reason, daemon: daemon, personalStateLoaded: { daemon.store.personal.isLoaded })
        })
    }

    init(readiness: @escaping @MainActor @Sendable (String) -> Readiness,
         patience: Duration = PendingOpenPatience.limit, clock: any Clock<Duration> = ContinuousClock()) {
        self.readiness = readiness
        self.patience = patience
        expiry = DemandTimer(owner: "daemon.startupWait", clock: clock)
    }

    /// Whether a run refused for `reason` waits for cmux to finish starting.
    public nonisolated static func waits(for reason: String) -> Bool { reasons.contains(reason) }

    /// The reasons that pass by themselves once cmux is ready.
    nonisolated static var reasons: [String] { [RefusalStrings.daemonConnecting, RefusalStrings.personalStateLoading] }

    static func state(of reason: String, daemon: DaemonService, personalStateLoaded: @MainActor () -> Bool) -> Readiness {
        if reason == RefusalStrings.personalStateLoading {
            if personalStateLoaded() { return .ready }
            return daemon.personalStateMayLoad ? .waiting : .failed
        }
        if daemon.startup.isUnavailable { return .failed }
        return daemon.identity != nil && PendingSessionOpen.ready(daemon) ? .ready : .waiting
    }

    /// Runs waiting now.
    var waitingCount: Int { held.count }

    /// Holds a person's runs that cmux still starting would refuse: an action off for that reason
    /// takes this way past it, and a handler's refusal for it keeps the run. The registry keeps this
    /// wait alive (its closures hold it; it holds the registry weakly).
    public func bind(into registry: ActionRegistry) {
        self.registry = registry
        registry.unavailableRecoveries.append { [self] _, reason in
            guard Self.waits(for: reason), !replaying else { return nil }
            return ActionRecovery { [self] id, invocation in
                guard !hold(reason, { [weak self] in self?.replay(id, invocation) }), let registry = self.registry else { return }
                registry.refuse(registry.unavailableReason(for: id) ?? reason)
            }
        }
        registry.refusalDeferrals.append { [self] id, invocation, reason in
            hold(reason) { [weak self] in self?.replay(id, invocation) }
        }
    }

    /// Performs a held run for the person the way a sign-in resumes one
    /// (``CloudSignInRecovery/resume(_:_:in:)``): a reason that still holds once cmux is ready is shown.
    private func replay(_ id: ActionID, _ invocation: ActionInvocation) {
        guard let registry else { return }
        CloudSignInRecovery.resume(id, invocation, in: registry)
    }

    /// Keeps `run` until the wait for `reason` ends; false (nothing kept) when `reason` does not wait,
    /// the wait already ended, or held runs are being performed again.
    @discardableResult
    func hold(_ reason: String, _ run: @escaping @MainActor () -> Void) -> Bool {
        guard Self.waits(for: reason), !replaying, readiness(reason) == .waiting else { return false }
        held.append(Held(reason: reason, run: run))
        if held.count == 1 {
            expiry.schedule(after: patience) { @MainActor [weak self] in self?.drop() }
        }
        guard watch == nil else { return true }
        // task-owner: this wait (app lifetime); ends when no run waits (`advance`, `drop`).
        // Every waiting reason is read, not only the front run's: a front run that goes leaves the next one waiting on another.
        watch = Task { [weak self] in
            guard let readiness = self?.readiness else { return }
            for await _ in ObservationStream({ Self.reasons.map(readiness) }) {
                guard let self else { return }
                if advance() { return }
            }
        }
        return true
    }

    /// Runs the held runs from the front, in order, while their wait is over; drops them all once one
    /// can no longer run. True once none waits.
    private func advance() -> Bool {
        while let first = held.first {
            switch readiness(first.reason) {
            case .waiting: return false
            case .failed: drop(); return true
            case .ready:
                held.removeFirst()
                replaying = true
                first.run()
                replaying = false
            }
        }
        end()
        return true
    }

    /// Drops every held run and says so once.
    private func drop() {
        guard !held.isEmpty else { return }
        held = []
        end()
        registry?.refuse(RefusalStrings.startupWaitDropped)
    }

    private func end() {
        expiry.cancel()
        watch?.cancel()
        watch = nil
    }
}

nonisolated extension RefusalStrings {
    /// What a person did while cmux was starting did not run: the service did not start, or was not
    /// ready within ``PendingOpenPatience/limit`` (``DaemonStartupWait``).
    public static var startupWaitDropped: String {
        text("refusal.daemon.startupWaitDropped", "cmux didn’t finish starting, so what you did while it started didn’t run.")
    }
}
