public import CMUXMobileCore
public import Foundation

/// Locally authenticates pair grants, then enforces current broker revocation policy.
public actor CmxIrohOnlineAdmissionRegistry {
    public typealias InvalidationHandler = @Sendable () async -> Void

    private struct Snapshot: Sendable {
        let response: CmxIrohDiscoveryResponse
        let fetchedAt: Date
    }

    private struct Refresh: Sendable {
        let id: UUID
        let task: Task<CmxIrohDiscoveryResponse, any Error>
    }

    private struct Monitor {
        let lease: CmxIrohOnlineAdmissionLease
        let onInvalidated: InvalidationHandler
        let task: Task<Void, Never>
    }

    private enum Revalidation {
        case active(Date)
        case connectivity
        case terminal
    }

    /// A successful broker snapshot is reused for no more than 30 seconds.
    public static let maximumOnlineSnapshotAge: TimeInterval = 30

    private let broker: any CmxIrohDiscoveryServing
    private let managedRelayURLs: Set<String>
    private let routeContractVersion: Int
    private let verifier: CmxIrohGrantVerifier
    private let clock: any CmxIrohRelayClock
    private var keys: CmxIrohGrantVerificationKeySet
    private var acceptor: CmxIrohGrantPeer
    private var snapshot: Snapshot?
    private var refresh: Refresh?
    private var deniedBindingIDs: Set<String> = []
    private var monitors: [UUID: Monitor] = [:]

    public init(
        broker: any CmxIrohDiscoveryServing,
        keys: CmxIrohGrantVerificationKeySet,
        acceptor: CmxIrohGrantPeer,
        managedRelayURLs: Set<String>,
        routeContractVersion: Int = 1,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    ) {
        self.broker = broker
        self.keys = keys
        self.acceptor = acceptor
        self.managedRelayURLs = managedRelayURLs
        self.routeContractVersion = routeContractVersion
        self.verifier = verifier
        self.clock = clock
    }

    /// Replaces locally trusted grant keys and the exact current Mac binding.
    public func update(
        keys: CmxIrohGrantVerificationKeySet,
        acceptor: CmxIrohGrantPeer
    ) {
        self.keys = keys
        self.acceptor = acceptor
        snapshot = nil
    }

    /// Verifies signature and TLS identity before consulting the authenticated broker.
    public func authorizePairGrant(
        _ token: String,
        authenticatedPeerID: CmxIrohPeerIdentity
    ) async -> CmxIrohOnlineAdmissionAuthorization {
        let claims: CmxIrohPairGrantClaims
        do {
            claims = try verifier.verifyPairGrant(
                token,
                keys: keys,
                authenticatedInitiatorID: authenticatedPeerID,
                acceptor: acceptor,
                now: clock.now()
            )
        } catch {
            return .denied
        }
        guard !isDenied(claims) else { return .denied }

        do {
            let online = try await currentSnapshot()
            guard validate(online.response, claims: claims, learnDenial: true) else {
                await invalidateDeniedMonitors()
                return .denied
            }
            guard !isExpired(claims) else {
                return .denied
            }
            return .accepted(
                CmxIrohOnlineAdmissionLease(
                    claims: claims,
                    onlineValidatedAt: online.fetchedAt
                )
            )
        } catch {
            guard Self.isConnectivity(error),
                  !isDenied(claims),
                  !isExpired(claims) else {
                return .denied
            }
            return .accepted(
                CmxIrohOnlineAdmissionLease(claims: claims, onlineValidatedAt: nil)
            )
        }
    }

    /// Starts an idle-safe lease monitor. Only the supplied session callback is invalidated.
    @discardableResult
    public func monitor(
        _ lease: CmxIrohOnlineAdmissionLease,
        onInvalidated: @escaping InvalidationHandler
    ) -> UUID {
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.monitorLoop(id: id, lease: lease, onInvalidated: onInvalidated)
        }
        monitors[id] = Monitor(
            lease: lease,
            onInvalidated: onInvalidated,
            task: task
        )
        return id
    }

    /// Applies local revoke state immediately to new and already-admitted sessions.
    public func revoke(bindingID: String) async {
        deniedBindingIDs.insert(bindingID)
        await invalidateDeniedMonitors()
    }

    /// Stops monitoring a session that has already closed normally.
    public func stopMonitoring(_ id: UUID) {
        monitors.removeValue(forKey: id)?.task.cancel()
    }

    /// Cancels all lease timers without changing endpoint ownership.
    public func stop() {
        let active = monitors.values
        monitors.removeAll()
        for monitor in active { monitor.task.cancel() }
        refresh?.task.cancel()
        refresh = nil
    }

    private func monitorLoop(
        id: UUID,
        lease: CmxIrohOnlineAdmissionLease,
        onInvalidated: @escaping InvalidationHandler
    ) async {
        var nextOnlineCheck = lease.onlineValidatedAt?
            .addingTimeInterval(Self.maximumOnlineSnapshotAge)
            ?? clock.now().addingTimeInterval(Self.maximumOnlineSnapshotAge)

        while !Task.isCancelled {
            let deadline = min(lease.expiresAt, nextOnlineCheck)
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard monitors[id] != nil else { return }
            if clock.now() >= lease.expiresAt || isDenied(lease) {
                await invalidate(id: id, onInvalidated: onInvalidated)
                return
            }

            switch await revalidate(lease) {
            case let .active(fetchedAt):
                nextOnlineCheck = fetchedAt.addingTimeInterval(
                    Self.maximumOnlineSnapshotAge
                )
            case .connectivity:
                nextOnlineCheck = clock.now().addingTimeInterval(
                    Self.maximumOnlineSnapshotAge
                )
            case .terminal:
                await invalidate(id: id, onInvalidated: onInvalidated)
                return
            }
        }
    }

    private func revalidate(_ lease: CmxIrohOnlineAdmissionLease) async -> Revalidation {
        guard !isDenied(lease), clock.now() < lease.expiresAt else {
            return .terminal
        }
        do {
            let online = try await currentSnapshot()
            guard validate(online.response, lease: lease, learnDenial: true) else {
                await invalidateDeniedMonitors()
                return .terminal
            }
            guard clock.now() < lease.expiresAt else {
                return .terminal
            }
            return .active(online.fetchedAt)
        } catch {
            return Self.isConnectivity(error) && !isDenied(lease)
                ? .connectivity
                : .terminal
        }
    }

    private func currentSnapshot() async throws -> Snapshot {
        let now = clock.now()
        if let snapshot,
           now >= snapshot.fetchedAt,
           now.timeIntervalSince(snapshot.fetchedAt) < Self.maximumOnlineSnapshotAge {
            return snapshot
        }
        let operation: Refresh
        if let refresh {
            operation = refresh
        } else {
            let id = UUID()
            let broker = broker
            operation = Refresh(
                id: id,
                task: Task { try await broker.discover() }
            )
            refresh = operation
        }
        do {
            let response = try await operation.task.value
            let fetchedAt = clock.now()
            let current = Snapshot(response: response, fetchedAt: fetchedAt)
            if refresh?.id == operation.id {
                refresh = nil
                snapshot = current
            }
            return current
        } catch {
            if refresh?.id == operation.id { refresh = nil }
            throw error
        }
    }

    private func validate(
        _ response: CmxIrohDiscoveryResponse,
        claims: CmxIrohPairGrantClaims,
        learnDenial: Bool
    ) -> Bool {
        validate(
            response,
            initiator: claims.initiator,
            acceptor: claims.acceptor,
            learnDenial: learnDenial
        )
    }

    private func validate(
        _ response: CmxIrohDiscoveryResponse,
        lease: CmxIrohOnlineAdmissionLease,
        learnDenial: Bool
    ) -> Bool {
        validate(
            response,
            initiator: lease.initiator,
            acceptor: lease.acceptor,
            learnDenial: learnDenial
        )
    }

    private func validate(
        _ response: CmxIrohDiscoveryResponse,
        initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        learnDenial: Bool
    ) -> Bool {
        guard response.routeContractVersion == routeContractVersion,
              Set(response.relayFleet) == managedRelayURLs else {
            return false
        }
        let initiatorMatches = response.bindings.filter {
            CmxIrohGrantPeer(binding: $0) == initiator
        }
        let acceptorMatches = response.bindings.filter {
            CmxIrohGrantPeer(binding: $0) == acceptor
        }
        let initiatorIdentityMatches = response.bindings.filter {
            $0.endpointID == initiator.endpointID && $0.platform == initiator.platform
        }
        let acceptorIdentityMatches = response.bindings.filter {
            $0.endpointID == acceptor.endpointID && $0.platform == acceptor.platform
        }
        let initiatorActive = initiatorMatches.count == 1
            && initiatorIdentityMatches.count == 1
        let acceptorActive = acceptorMatches.count == 1
            && acceptorIdentityMatches.count == 1
            && acceptorMatches[0].pairingEnabled
        if learnDenial {
            if !initiatorActive { deniedBindingIDs.insert(initiator.bindingID) }
            if !acceptorActive { deniedBindingIDs.insert(acceptor.bindingID) }
        }
        return initiatorActive && acceptorActive
    }

    private func isDenied(_ claims: CmxIrohPairGrantClaims) -> Bool {
        deniedBindingIDs.contains(claims.initiator.bindingID)
            || deniedBindingIDs.contains(claims.acceptor.bindingID)
    }

    private func isDenied(_ lease: CmxIrohOnlineAdmissionLease) -> Bool {
        deniedBindingIDs.contains(lease.initiator.bindingID)
            || deniedBindingIDs.contains(lease.acceptor.bindingID)
    }

    private func isExpired(_ claims: CmxIrohPairGrantClaims) -> Bool {
        TimeInterval(claims.expiresAt) <= clock.now().timeIntervalSince1970
    }

    private func invalidate(
        id: UUID,
        onInvalidated: @escaping InvalidationHandler
    ) async {
        guard monitors.removeValue(forKey: id) != nil else { return }
        await onInvalidated()
    }

    private func invalidateDeniedMonitors() async {
        let denied = monitors.filter { isDenied($0.value.lease) }
        for id in denied.keys { monitors[id] = nil }
        for monitor in denied.values { monitor.task.cancel() }
        for monitor in denied.values { await monitor.onInvalidated() }
    }

    private static func isConnectivity(_ error: any Error) -> Bool {
        (error as? CmxIrohTrustBrokerClientError) == .connectivity
    }
}
