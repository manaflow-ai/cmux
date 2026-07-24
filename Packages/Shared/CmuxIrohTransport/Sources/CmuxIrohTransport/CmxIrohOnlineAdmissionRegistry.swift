public import CMUXMobileCore
public import Foundation

/// Locally authenticates pair grants, then enforces current broker revocation policy.
public actor CmxIrohOnlineAdmissionRegistry {
    public typealias InvalidationHandler = @Sendable () async -> Void

    private struct Snapshot: Sendable {
        let id: UUID
        let response: CmxIrohDiscoveryResponse
        let fetchedAt: Date
    }

    private struct SnapshotRead: Sendable {
        let snapshot: Snapshot
        let reusedCachedSnapshot: Bool
    }

    private struct Refresh: Sendable {
        let id: UUID
        let task: Task<CmxIrohDiscoveryResponse, any Error>
    }

    private struct Monitor {
        let lease: CmxIrohOnlineAdmissionLease
        let onInvalidated: InvalidationHandler
        let task: Task<Void, Never>?
        let connectionLifetimeTask: Task<Void, Never>?
    }

    private enum Revalidation {
        case active(Date)
        case connectivity
        case terminal
    }

    /// A successful broker snapshot is reused for no more than 30 seconds.
    public static let maximumOnlineSnapshotAge: TimeInterval = 30

    private let broker: any CmxIrohDiscoveryServing
    private var managedRelayURLs: Set<String>
    private let routeContractVersion: Int
    private let verifier: CmxIrohGrantVerifier
    private let clock: any CmxIrohRelayClock
    private var keys: CmxIrohGrantVerificationKeySet
    private var acceptor: CmxIrohGrantPeer
    private var snapshot: Snapshot?
    private var refresh: Refresh?
    private var policyRevision: UInt64 = 0
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
        policyRevision &+= 1
        snapshot = nil
        refresh?.task.cancel()
        refresh = nil
    }

    /// Replaces the verified managed fleet used for online revalidation.
    func updateManagedRelayURLs(_ relayURLs: Set<String>) {
        managedRelayURLs = relayURLs
        policyRevision &+= 1
        snapshot = nil
        refresh?.task.cancel()
        refresh = nil
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
        return await authorize(
            CmxIrohOnlineAdmissionLease(claims: claims, onlineValidatedAt: nil)
        )
    }

    /// AdmissionController is the only production caller, after locally verifying and
    /// consuming the one-use proof, TLS identity, and both signed attestations.
    func authorizeOfflinePair(
        _ pair: CmxIrohVerifiedOfflinePair
    ) async -> CmxIrohOnlineAdmissionAuthorization {
        let lease = CmxIrohOnlineAdmissionLease(pair: pair, onlineValidatedAt: nil)
        let verifiedAcceptor = CmxIrohEndpointExpectation(
            bindingID: pair.acceptor.bindingID,
            deviceID: pair.acceptor.deviceID,
            endpointID: pair.acceptor.endpointID,
            identityGeneration: pair.acceptor.identityGeneration,
            platform: pair.acceptor.platform
        )
        guard pair.initiator.platform == .ios,
              pair.acceptor.platform == .mac,
              currentAcceptorExpectation() == verifiedAcceptor else {
            return .denied
        }
        return await authorize(lease)
    }

    private func authorize(
        _ lease: CmxIrohOnlineAdmissionLease
    ) async -> CmxIrohOnlineAdmissionAuthorization {
        guard !isDenied(lease), !isExpired(lease) else { return .denied }
        let revision = policyRevision
        do {
            guard let online = try await validatedSnapshot(
                for: lease,
                policyRevision: revision
            ) else {
                await invalidateDeniedMonitors()
                return .denied
            }
            guard !isExpired(lease) else {
                return .denied
            }
            return .accepted(lease.validatedOnline(at: online.fetchedAt))
        } catch {
            guard Self.isConnectivity(error),
                  policyRevision == revision,
                  !isDenied(lease),
                  !isExpired(lease) else {
                return .denied
            }
            return .accepted(lease)
        }
    }

    /// Starts an idle-safe lease monitor owned by the exact live connection.
    ///
    /// Normal connection close removes the monitor. Revocation, terminal broker
    /// failure, or lease expiry invokes only the supplied session callback.
    public func monitor(
        _ lease: CmxIrohOnlineAdmissionLease,
        connection: any CmxIrohConnection,
        onInvalidated: @escaping InvalidationHandler
    ) {
        let id = UUID()
        monitors[id] = Monitor(
            lease: lease,
            onInvalidated: onInvalidated,
            task: nil,
            connectionLifetimeTask: nil
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.monitorLoop(id: id, lease: lease, onInvalidated: onInvalidated)
        }
        let connectionLifetimeTask = Task { [weak self] in
            await connection.waitUntilClosed()
            await self?.connectionClosed(id: id)
        }
        if let monitor = monitors[id] {
            monitors[id] = Monitor(
                lease: monitor.lease,
                onInvalidated: monitor.onInvalidated,
                task: task,
                connectionLifetimeTask: connectionLifetimeTask
            )
        } else {
            task.cancel()
            connectionLifetimeTask.cancel()
        }
    }

    /// Applies local revoke state immediately to new and already-admitted sessions.
    public func revoke(bindingID: String) async {
        deniedBindingIDs.insert(bindingID)
        policyRevision &+= 1
        await invalidateDeniedMonitors()
    }

    /// Cancels all lease timers without changing endpoint ownership.
    public func stop() {
        let active = monitors.values
        monitors.removeAll()
        for monitor in active {
            monitor.task?.cancel()
            monitor.connectionLifetimeTask?.cancel()
        }
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
        let revision = policyRevision
        do {
            guard let online = try await validatedSnapshot(
                for: lease,
                policyRevision: revision
            ) else {
                await invalidateDeniedMonitors()
                return .terminal
            }
            guard clock.now() < lease.expiresAt else {
                return .terminal
            }
            return .active(online.fetchedAt)
        } catch {
            return Self.isConnectivity(error)
                && policyRevision == revision
                && !isDenied(lease)
                ? .connectivity
                : .terminal
        }
    }

    private func validatedSnapshot(
        for lease: CmxIrohOnlineAdmissionLease,
        policyRevision expectedRevision: UInt64
    ) async throws -> Snapshot? {
        let initial = try await currentSnapshot()
        guard policyRevision == expectedRevision, !isDenied(lease) else {
            return nil
        }
        if validate(
            initial.snapshot.response,
            lease: lease,
            learnDenial: !initial.reusedCachedSnapshot
        ) {
            return initial.snapshot
        }
        guard initial.reusedCachedSnapshot else { return nil }

        let refreshed = try await currentSnapshot(
            excludingCachedSnapshotID: initial.snapshot.id
        )
        guard policyRevision == expectedRevision,
              !isDenied(lease),
              validate(
                  refreshed.snapshot.response,
                  lease: lease,
                  learnDenial: true
              ) else {
            return nil
        }
        return refreshed.snapshot
    }

    private func currentSnapshot(
        excludingCachedSnapshotID excludedSnapshotID: UUID? = nil
    ) async throws -> SnapshotRead {
        let now = clock.now()
        if let snapshot,
           snapshot.id != excludedSnapshotID,
           now >= snapshot.fetchedAt,
           now.timeIntervalSince(snapshot.fetchedAt) < Self.maximumOnlineSnapshotAge {
            return SnapshotRead(
                snapshot: snapshot,
                reusedCachedSnapshot: excludedSnapshotID == nil
            )
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
            let current = Snapshot(
                id: operation.id,
                response: response,
                fetchedAt: fetchedAt
            )
            if refresh?.id == operation.id {
                refresh = nil
                snapshot = current
            }
            return SnapshotRead(snapshot: current, reusedCachedSnapshot: false)
        } catch {
            if refresh?.id == operation.id { refresh = nil }
            throw error
        }
    }

    private func validate(
        _ response: CmxIrohDiscoveryResponse,
        lease: CmxIrohOnlineAdmissionLease,
        learnDenial: Bool
    ) -> Bool {
        guard response.routeContractVersion == routeContractVersion,
              Set(response.relayFleet) == managedRelayURLs else {
            return false
        }
        switch lease.authority {
        case let .pairGrant(_, initiator, acceptor):
            return validatePairGrantBindings(
                response.bindings,
                initiator: initiator,
                acceptor: acceptor,
                learnDenial: learnDenial
            )
        case let .offlinePairing(initiator, acceptor):
            return validateOfflineBindings(
                response.bindings,
                initiator: initiator,
                acceptor: acceptor,
                learnDenial: learnDenial
            )
        }
    }

    private func validatePairGrantBindings(
        _ bindings: [CmxIrohBrokerBinding],
        initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        learnDenial: Bool
    ) -> Bool {
        let initiatorMatches = bindings.filter {
            CmxIrohGrantPeer(binding: $0) == initiator
        }
        let acceptorMatches = bindings.filter {
            CmxIrohGrantPeer(binding: $0) == acceptor
        }
        let initiatorIdentityMatches = bindings.filter {
            $0.endpointID == initiator.endpointID && $0.platform == initiator.platform
        }
        let acceptorIdentityMatches = bindings.filter {
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

    private func validateOfflineBindings(
        _ bindings: [CmxIrohBrokerBinding],
        initiator: CmxIrohEndpointExpectation,
        acceptor: CmxIrohEndpointExpectation,
        learnDenial: Bool
    ) -> Bool {
        let initiatorMatches = bindings.filter { Self.matches($0, expectation: initiator) }
        let acceptorMatches = bindings.filter { Self.matches($0, expectation: acceptor) }
        let initiatorIdentityMatches = bindings.filter {
            $0.endpointID == initiator.endpointID && $0.platform == initiator.platform
        }
        let acceptorIdentityMatches = bindings.filter {
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

    private func isDenied(_ lease: CmxIrohOnlineAdmissionLease) -> Bool {
        deniedBindingIDs.contains(lease.authority.initiatorBindingID)
            || deniedBindingIDs.contains(lease.authority.acceptorBindingID)
    }

    private func isExpired(_ lease: CmxIrohOnlineAdmissionLease) -> Bool {
        lease.expiresAt <= clock.now()
    }

    private func currentAcceptorExpectation() -> CmxIrohEndpointExpectation {
        CmxIrohEndpointExpectation(
            bindingID: acceptor.bindingID,
            deviceID: acceptor.deviceID,
            endpointID: acceptor.endpointID,
            identityGeneration: acceptor.identityGeneration,
            platform: acceptor.platform
        )
    }

    private static func matches(
        _ binding: CmxIrohBrokerBinding,
        expectation: CmxIrohEndpointExpectation
    ) -> Bool {
        binding.bindingID == expectation.bindingID
            && binding.deviceID == expectation.deviceID
            && binding.endpointID == expectation.endpointID
            && binding.identityGeneration == expectation.identityGeneration
            && binding.platform == expectation.platform
    }

    private func invalidate(
        id: UUID,
        onInvalidated: @escaping InvalidationHandler
    ) async {
        guard let monitor = monitors.removeValue(forKey: id) else { return }
        monitor.connectionLifetimeTask?.cancel()
        await onInvalidated()
    }

    private func connectionClosed(id: UUID) {
        guard let monitor = monitors.removeValue(forKey: id) else { return }
        monitor.task?.cancel()
    }

    private func invalidateDeniedMonitors() async {
        let denied = monitors.filter { isDenied($0.value.lease) }
        for id in denied.keys { monitors[id] = nil }
        for monitor in denied.values {
            monitor.task?.cancel()
            monitor.connectionLifetimeTask?.cancel()
        }
        for monitor in denied.values { await monitor.onInvalidated() }
    }

    private static func isConnectivity(_ error: any Error) -> Bool {
        (error as? CmxIrohTrustBrokerClientError) == .connectivity
    }
}
