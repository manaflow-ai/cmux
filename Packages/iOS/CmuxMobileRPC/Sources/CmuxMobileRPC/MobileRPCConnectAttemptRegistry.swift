import Foundation

/// Tracks connection attempts for one owner.
///
/// `MobileCoreRPCSession` instances are short-lived around pairing and route
/// retries. This actor lets a larger owner, such as `MobileShellComposite`,
/// reserve a route before connect starts and retain every physical cleanup task
/// that outlives its session's bounded drain. Active admission and unresolved
/// cleanup debt are independent identities, so a successful recovery cannot
/// erase an older cleanup. One unresolved cleanup permits one recovery dial;
/// two block the route until either exact cleanup finishes.
public actor MobileRPCConnectAttemptRegistry {
    private static let maximumUnresolvedCleanupsPerRoute = 2

    private var routeStates:
        [MobileRPCConnectAttemptKey: MobileRPCConnectRouteState] = [:]
    private var untrackedPhysicalCleanupTasks: [UUID: Task<Void, Never>] = [:]

    /// Creates an empty registry.
    public init() {}

    func beginConnect(
        key: MobileRPCConnectAttemptKey?
    ) -> MobileRPCConnectAdmission {
        guard let key else { return .granted(.untracked) }
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
        guard let lease, let key = lease.key else { return }
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

    func recordSuccessfulConnect(lease: MobileRPCConnectAttemptLease?) {
        finishConnect(lease: lease)
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
