import Foundation

/// Tracks physical connection resources for one shell owner.
///
/// A session reserves before connect, keeps that lease while its transport is
/// installed, and transfers the lease to any physical cleanup that outlives
/// its bounded drain. Active sessions and unresolved cleanup debt are
/// independent identities, so a successful recovery cannot erase an older
/// cleanup. One unresolved cleanup permits one recovery dial; two block the
/// route until either exact cleanup finishes. A global admission budget bounds
/// live transports, active dials, and cleanup debt across all routes.
public actor MobileRPCConnectAttemptRegistry {
    private static let maximumUnresolvedCleanupsPerRoute = 2
    private static let maximumGlobalOutstandingAttempts = 16

    private var routeStates:
        [MobileRPCConnectAttemptKey: MobileRPCConnectRouteState] = [:]
    private var activeUntrackedLeaseIDs: Set<UUID> = []
    private var untrackedPhysicalCleanupTasks: [UUID: Task<Void, Never>] = [:]

    /// Creates an empty registry.
    public init() {}

    func beginConnect(
        key: MobileRPCConnectAttemptKey?
    ) -> MobileRPCConnectAdmission {
        guard unresolvedPhysicalCleanupCount
                < Self.maximumGlobalOutstandingAttempts else {
            return .cleanupBlocked
        }
        guard globalOutstandingAttemptCount
                < Self.maximumGlobalOutstandingAttempts else {
            return .busy
        }
        guard let key else {
            let lease = MobileRPCConnectAttemptLease(
                key: nil,
                id: UUID()
            )
            activeUntrackedLeaseIDs.insert(lease.id)
            return .granted(lease)
        }
        var state = routeStates[key] ?? MobileRPCConnectRouteState()
        guard state.activeLeaseID == nil else {
            return .busy
        }
        guard state.physicalCleanupTasks.count
                < Self.maximumUnresolvedCleanupsPerRoute else {
            return .cleanupBlocked
        }
        let lease = MobileRPCConnectAttemptLease(key: key, id: UUID())
        state.activeLeaseID = lease.id
        routeStates[key] = state
        return .granted(lease)
    }

    func finishConnect(lease: MobileRPCConnectAttemptLease?) {
        guard let lease else { return }
        guard let key = lease.key else {
            activeUntrackedLeaseIDs.remove(lease.id)
            return
        }
        guard var state = routeStates[key],
              state.activeLeaseID == lease.id else {
            return
        }
        state.activeLeaseID = nil
        store(state, forKey: key)
    }

    func handOffPhysicalCleanup(
        lease: MobileRPCConnectAttemptLease?,
        operation: @escaping @Sendable () async -> Void
    ) {
        guard let lease, let key = lease.key else {
            let cleanupID = lease?.id ?? UUID()
            activeUntrackedLeaseIDs.remove(cleanupID)
            untrackedPhysicalCleanupTasks[cleanupID] = Task.detached {
                [weak self] in
                await operation()
                await self?.untrackedPhysicalCleanupDidFinish(cleanupID)
            }
            return
        }

        var state = routeStates[key] ?? MobileRPCConnectRouteState()
        guard state.physicalCleanupTasks[lease.id] == nil else {
            return
        }
        if state.activeLeaseID == lease.id {
            state.activeLeaseID = nil
        }
        state.physicalCleanupTasks[lease.id] = Task.detached {
            [weak self] in
            await operation()
            await self?.physicalCleanupDidFinish(
                key: key,
                cleanupID: lease.id
            )
        }
        routeStates[key] = state
    }

    public func resetRouteHealthForNetworkChange() {
        // Current main keeps only active leases and physical cleanup debt. Those
        // are ownership facts, not route-health strikes, so a network change must
        // not erase them and accidentally admit duplicate dials.
        for (key, state) in routeStates
            where state.activeLeaseID == nil && state.physicalCleanupTasks.isEmpty {
            routeStates[key] = nil
        }
    }

    private func physicalCleanupDidFinish(
        key: MobileRPCConnectAttemptKey,
        cleanupID: UUID
    ) {
        guard var state = routeStates[key],
              state.physicalCleanupTasks.removeValue(
                  forKey: cleanupID
              ) != nil else {
            return
        }
        store(state, forKey: key)
    }

    private func untrackedPhysicalCleanupDidFinish(_ cleanupID: UUID) {
        untrackedPhysicalCleanupTasks[cleanupID] = nil
    }

    private var unresolvedPhysicalCleanupCount: Int {
        untrackedPhysicalCleanupTasks.count
            + routeStates.values.reduce(into: 0) {
                $0 += $1.physicalCleanupTasks.count
            }
    }

    private var globalOutstandingAttemptCount: Int {
        unresolvedPhysicalCleanupCount
            + activeUntrackedLeaseIDs.count
            + routeStates.values.reduce(into: 0) {
                if $1.activeLeaseID != nil {
                    $0 += 1
                }
            }
    }

    private func store(
        _ state: MobileRPCConnectRouteState,
        forKey key: MobileRPCConnectAttemptKey
    ) {
        if state.activeLeaseID == nil,
           state.physicalCleanupTasks.isEmpty {
            routeStates[key] = nil
        } else {
            routeStates[key] = state
        }
    }
}
