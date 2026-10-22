import CmuxNextWakeups
import Foundation

/// A restart of a session owner that may run only while it is idle: a DEV app's one install-key
/// restart of its keyless Chief owner (cx-ebm.59.5, `OwnerIdleProbe`), and the restart of a
/// stale local cmux-tui at a quiet moment (`QuietDaemonUpdate`). `attempt` tries at once. While
/// the owner is busy, `note` tries again on each owner event that can end the business: a client
/// left or changed its kind (an open `cmux chief` chat ends, another app or a page disconnects)
/// or a typing set changed (a Chief turn ends). With a ``Retry``, a busy probe also arms one
/// bounded deadline that tries again, a limited number of times (business with no owner event,
/// such as the person typing). It restarts at most once.
public actor IdleOwnerRestart {
    public enum Outcome: Equatable, Sendable {
        /// No restart yet: the owner was busy.
        case waiting
        /// The owner accepted the restart.
        case started
        /// The owner refused the restart; it is not tried again.
        case refused
    }

    /// Timed retries after a busy probe: one deadline at a time, `count` in all, then events only.
    public struct Retry: Sendable {
        public var interval: Duration
        public var count: Int
        public var clock: any Clock<Duration>

        public init(interval: Duration, count: Int, clock: any Clock<Duration> = ContinuousClock()) {
            self.interval = interval
            self.count = count
            self.clock = clock
        }
    }

    public private(set) var outcome: Outcome = .waiting
    private let isIdle: @Sendable () async -> Bool
    private let restart: @Sendable () async -> Bool
    private let retry: Retry?
    private let retryTimer: DemandTimer?
    private var retriesLeft: Int
    /// `stop` ended it: no more probes.
    private var stopped = false
    /// A probe runs now. One attempt that came meanwhile waits here and probes next (its event
    /// may have come after the running probe read the owner); later ones are covered by it.
    private var probing = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    public init(probe: OwnerIdleProbe, restart: @escaping @Sendable () async -> Bool) {
        self.init(isIdle: { await probe.isIdle() }, restart: restart)
    }

    /// - Parameters:
    ///   - isIdle: Whether the owner may restart now; false keeps it waiting.
    ///   - retry: Timed retries after a busy probe; nil: owner events only.
    public init(isIdle: @escaping @Sendable () async -> Bool, retry: Retry? = nil,
                restart: @escaping @Sendable () async -> Bool) {
        self.isIdle = isIdle
        self.restart = restart
        self.retry = retry
        retriesLeft = retry?.count ?? 0
        retryTimer = retry.map { DemandTimer(owner: "daemon.idleOwnerRestart.retry", clock: $0.clock) }
    }

    /// Ends the wait: no further probe or timed retry (the daemon changed, the toggle went off).
    public func stop() {
        stopped = true
        retryTimer?.cancel()
    }

    /// Restarts the owner if it is idle now; the outcome. Each call runs at most one probe: one
    /// that comes during a running probe runs its own probe right after it (the event that asked
    /// may have come after the running probe read the owner); a call when one already waits
    /// returns at once, because that waiting probe reads the owner after this event too.
    @discardableResult
    public func attempt() async -> Outcome {
        guard outcome == .waiting, !stopped else { return outcome }
        if probing {
            guard queued.isEmpty else { return outcome }
            // The running probe hands over to this one when it ends (`probing` stays true).
            await withCheckedContinuation { queued.append($0) }
            guard outcome == .waiting, !stopped else {
                finishProbe()
                return outcome
            }
        } else {
            probing = true
        }
        if await isIdle(), !stopped {
            outcome = await restart() ? .started : .refused
        }
        finishProbe()
        scheduleRetry()
        return outcome
    }

    /// After a busy probe: one deadline that tries again, while the retry budget lasts.
    private func scheduleRetry() {
        guard outcome == .waiting, !stopped, let retry, let retryTimer, retriesLeft > 0, !retryTimer.isScheduled else { return }
        retriesLeft -= 1
        retryTimer.schedule(after: retry.interval) { [weak self] in _ = await self?.attempt() }
    }

    /// Ends this probe: hands over to the waiting attempt, if any.
    private func finishProbe() {
        if queued.isEmpty {
            probing = false
        } else {
            queued.removeFirst().resume()
        }
    }

    /// An event of the owner's connection: tries again when it can end the owner's
    /// business; the outcome.
    @discardableResult
    public func note(_ event: DaemonEvent) async -> Outcome {
        guard outcome == .waiting, !stopped, Self.mayEndBusy(event) else { return outcome }
        return await attempt()
    }

    /// Whether `event` can make a busy owner idle.
    public static func mayEndBusy(_ event: DaemonEvent) -> Bool {
        switch event {
        case .client(let name, _):
            return name == "client-detached" || name == "client-changed" || name == "client-list-invalidated"
        case .conversationTyping:
            return true
        default:
            return false
        }
    }
}
