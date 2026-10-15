import Foundation

/// A restart of a conversation owner that may run only while the owner is idle
/// (`OwnerIdleProbe`): a DEV app's one install-key restart of its keyless Chief
/// owner (cx-ebm.59.5). `attempt` tries at once. While the owner is busy, `note`
/// tries again on each owner event that can end the business: a client left or
/// changed its kind (an open `cmux chief` chat ends, another app or a page
/// disconnects) or a typing set changed (a Chief turn ends). It restarts at most once.
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
    /// A probe runs now; an attempt meanwhile asks it to probe once more.
    private var probing = false
    private var again = false

    public init(probe: OwnerIdleProbe, restart: @escaping @Sendable () async -> Bool) {
        self.probe = probe
        self.restart = restart
    }

    /// Restarts the owner if it is idle now; the outcome. An attempt during a running
    /// probe makes that probe run once more when it finds the owner busy (the event that
    /// asked for it may have come after the probe read the owner).
    @discardableResult
    public func attempt() async -> Outcome {
        guard outcome == .waiting else { return outcome }
        guard !probing else {
            again = true
            return outcome
        }
        probing = true
        defer { probing = false }
        repeat {
            again = false
            if await probe.isIdle() {
                outcome = await restart() ? .started : .refused
                return outcome
            }
        } while again
        return outcome
    }

    /// An event of the owner's connection: tries again when it can end the owner's
    /// business; the outcome.
    @discardableResult
    public func note(_ event: DaemonEvent) async -> Outcome {
        guard outcome == .waiting, Self.mayEndBusy(event) else { return outcome }
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
