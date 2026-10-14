import Foundation

/// A restart of a conversation owner that may run only while the owner is idle
/// (`OwnerIdleProbe`): a DEV app's one install-key restart of its keyless Chief
/// owner (cx-ebm.59.5). `attempt` tries at once. It restarts at most once.
public actor IdleOwnerRestart {
    public enum Outcome: Equatable, Sendable {
        /// No restart yet: the owner was busy.
        case waiting
        /// The owner accepted the restart.
        case started
        /// The owner refused the restart; it is not tried again.
        case refused
    }

    public private(set) var outcome: Outcome = .waiting
    private let probe: OwnerIdleProbe
    private let restart: @Sendable () async -> Bool

    public init(probe: OwnerIdleProbe, restart: @escaping @Sendable () async -> Bool) {
        self.probe = probe
        self.restart = restart
    }

    /// Restarts the owner if it is idle now; the outcome.
    @discardableResult
    public func attempt() async -> Outcome {
        guard outcome == .waiting else { return outcome }
        if await probe.isIdle() {
            outcome = await restart() ? .started : .refused
        }
        return outcome
    }

    /// An event of the owner's connection; the outcome.
    @discardableResult
    public func note(_ event: DaemonEvent) async -> Outcome {
        outcome
    }
}
