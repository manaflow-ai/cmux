public import CmuxAuthRuntime

/// Owns the Cloud resources of one auth session, independently of the signed-in UI flag.
@MainActor
package final class CloudSessionLifecycle {
    package typealias Identity = AuthenticatedSessionIdentity
    package enum Retirement: Sendable, Equatable { case session, quit }
    private let current: @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool
    private let start: @MainActor @Sendable (AuthenticatedSessionIdentity) async -> Void
    private let retire: @MainActor @Sendable (Retirement) async -> Void
    private var identity: AuthenticatedSessionIdentity?
    private var desired: AuthenticatedSessionIdentity?
    private var needsRetire = true
    private var needsStart = false
    private var suspended = false
    private var stopped = false
    private var worker: Task<Void, Never>?

    package init(current: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) -> Bool,
                 start: @escaping @MainActor @Sendable (AuthenticatedSessionIdentity) async -> Void,
                 retire: @escaping @MainActor @Sendable (Retirement) async -> Void) {
        self.current = current; self.start = start; self.retire = retire
    }

    package func isCurrent(_ value: AuthenticatedSessionIdentity) -> Bool {
        !suspended && !stopped && identity == value && desired == value && current(value)
    }

    /// Returns the owned work so callers can join startup or retirement.
    package func update(_ value: AuthenticatedSessionIdentity?) -> Task<Void, Never> {
        if !stopped, desired != value { desired = value; needsStart = value != nil }
        return schedule()
    }

    /// Keep the latest auth identity while explicit sign-out drains the original session.
    package func suspend() -> Task<Void, Never> {
        suspended = true
        return schedule()
    }

    package func resume(_ value: AuthenticatedSessionIdentity?) -> Task<Void, Never> {
        if !stopped { suspended = false; desired = value; needsStart = value != nil }
        return schedule()
    }

    /// Policy changes retry startup without retiring an unchanged install or its enrollment.
    package func refresh(_ value: AuthenticatedSessionIdentity?) -> Task<Void, Never> {
        if !stopped, !suspended, let value, current(value) { desired = value; needsStart = true }
        return schedule()
    }

    /// Immediately fences late startup; its returned task joins local retirement.
    package func stop() -> Task<Void, Never> {
        stopped = true; desired = nil
        return schedule()
    }

    private func schedule() -> Task<Void, Never> {
        if let worker { return worker }
        // task-owner: worker; update/suspend/resume/stop join the same drain, never cancel it away.
        let task = Task { [weak self] in
            guard let self else { return }
            await drive()
            worker = nil
        }
        worker = task
        return task
    }

    private func drive() async {
        // wakeup-allow: each step awaits changed-session startup/retirement or returns; no timer or readiness polling.
        while true {
            let target = !suspended && !stopped ? desired.flatMap { current($0) ? $0 : nil } : nil
            if needsRetire || (identity != nil && identity != target) {
                identity = nil; needsRetire = false
                await retire(stopped ? .quit : .session)
                continue
            }
            if let target, identity == nil || needsStart {
                identity = target; needsStart = false
                await start(target)
                continue
            }
            return
        }
    }
}
