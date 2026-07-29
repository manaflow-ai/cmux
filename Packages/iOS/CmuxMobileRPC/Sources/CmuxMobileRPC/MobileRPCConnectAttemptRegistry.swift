import Foundation

/// Tracks connection attempts for one owner.
///
/// `MobileCoreRPCSession` instances are short-lived around pairing and route
/// retries. This actor lets a larger owner, such as `MobileShellComposite`,
/// reserve a route before connect starts, then release that exact reservation
/// when connect succeeds, fails, or its abandoned task cleanup finishes.
/// If cleanup gives up its retained task handle at the bounded cleanup deadline,
/// the registry allows one recovery attempt for that route. A second unresolved
/// cleanup hard-gates the route until its physical watcher finishes or this
/// process restarts. That keeps repeated scans from piling up unclosed
/// transports without making the first stuck task permanently poison a route.
public actor MobileRPCConnectAttemptRegistry {
    private static let maximumAbandonedAttemptsBeforeHardGate = 2

    private var routeStates: [String: MobileRPCConnectRouteState] = [:]

    /// Creates an empty registry.
    public init() {}

    func beginConnect(key: String?) -> MobileRPCConnectAttemptLease? {
        guard let key else { return .untracked }
        let abandonedAttempts: Int
        switch routeStates[key] {
        case nil:
            abandonedAttempts = 0
        case .released(_, let count):
            abandonedAttempts = count
        case .active, .hardGated:
            return nil
        }
        let id = UUID()
        routeStates[key] = .active(id: id, abandonedAttempts: abandonedAttempts)
        return MobileRPCConnectAttemptLease(key: key, id: id)
    }

    func markAbandoned(lease: MobileRPCConnectAttemptLease?) {
        guard let lease, let key = lease.key else { return }
        guard case .active(let id, let count) = routeStates[key], id == lease.id else { return }
        routeStates[key] = .active(id: lease.id, abandonedAttempts: count + 1)
    }

    func clearFinishedConnect(lease: MobileRPCConnectAttemptLease?) {
        guard let lease, let key = lease.key else { return }
        switch routeStates[key] {
        case .active(let id, _) where id == lease.id,
             .released(let id, _) where id == lease.id,
             .hardGated(let id, _) where id == lease.id:
            routeStates[key] = nil
        case nil, .active, .released, .hardGated:
            return
        }
    }

    func clearTimedOutAbandonedCleanup(lease: MobileRPCConnectAttemptLease?) {
        guard let lease, let key = lease.key else { return }
        guard case .active(let id, let count) = routeStates[key], id == lease.id else { return }
        guard count < Self.maximumAbandonedAttemptsBeforeHardGate else {
            routeStates[key] = .hardGated(
                id: lease.id,
                abandonedAttempts: count
            )
            return
        }
        routeStates[key] = .released(id: lease.id, abandonedAttempts: count)
    }

    func recordSuccessfulConnect(lease: MobileRPCConnectAttemptLease?) {
        clearFinishedConnect(lease: lease)
    }
}
