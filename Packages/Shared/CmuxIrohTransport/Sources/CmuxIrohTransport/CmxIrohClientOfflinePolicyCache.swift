import CryptoKit
public import CMUXMobileCore
public import Foundation

/// Stores a bounded set of signed pair authorities for connectivity-only fallback.
public actor CmxIrohClientOfflinePolicyCache {
    public static let maximumTargetCount = CmxIrohDiscoveryResponse.maximumBindingCount
    private static let storageAccount = "active-client-policies"

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let verifier: CmxIrohGrantVerifier
    private var lifecycleEpoch: UInt64 = 0
    private var deactivationCount = 0
    private var activeStorageMutationCount = 0
    private var storageMutationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.client-offline-policy.v1"
        ),
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier()
    ) {
        self.secureStore = secureStore
        self.verifier = verifier
    }

    /// Merges one online-verified target into the bounded active-account cache.
    public func save(
        localBinding: CmxIrohBrokerBinding,
        targetBinding: CmxIrohBrokerBinding,
        discovery: CmxIrohDiscoveryResponse,
        pairGrant: CmxIrohPairGrantResponse,
        for expectation: CmxIrohClientOfflinePolicyExpectation,
        now: Date
    ) async throws {
        let epoch = try beginOperation()
        try validateDiscovery(discovery, for: expectation)
        guard expectation.localBindingExpectation.matches(localBinding),
              discovery.bindings.filter({
                  expectation.localBindingExpectation.matches($0)
              }).count == 1,
              discovery.bindings.filter({ $0 == localBinding }).count == 1,
              discovery.bindings.filter({ $0 == targetBinding }).count == 1,
              discovery.bindings.filter({
                  $0.platform == .mac && $0.endpointID == targetBinding.endpointID
              }).count == 1,
              targetBinding.platform == .mac,
              targetBinding.pairingEnabled else {
            throw CmxIrohClientOfflinePolicyCacheError.invalidPolicy
        }
        try validateGrant(
            pairGrant,
            localBinding: localBinding,
            targetBinding: targetBinding,
            keys: discovery.grantVerificationKeys,
            now: now
        )

        var retained: [CmxIrohStoredClientPolicyTarget] = []
        let storedData = try await secureStore.read(account: Self.storageAccount)
        try requireCurrent(epoch)
        if let data = storedData,
           let record = try? JSONDecoder().decode(CmxIrohStoredClientPolicyRecord.self, from: data),
           record.version == CmxIrohStoredClientPolicyRecord.currentVersion,
           record.scopeDigest == Self.scopeDigest(for: expectation),
           Self.sameAuthority(record.localBinding, localBinding) {
            for stored in record.targets {
                guard let fresh = Self.uniqueBinding(
                    in: discovery.bindings,
                    matchingAuthorityOf: stored.binding
                ),
                    fresh.platform == .mac,
                    fresh.pairingEnabled,
                    (try? validateGrant(
                        stored.pairGrant,
                        localBinding: localBinding,
                        targetBinding: fresh,
                        keys: discovery.grantVerificationKeys,
                        now: now
                    )) != nil else {
                    continue
                }
                retained.append(.init(binding: fresh, pairGrant: stored.pairGrant))
            }
        }

        let candidate = CmxIrohStoredClientPolicyTarget(
            binding: targetBinding,
            pairGrant: pairGrant
        )
        var merged = [candidate]
        merged.append(contentsOf: retained.filter {
            $0.binding.deviceID != targetBinding.deviceID
                && $0.binding.endpointID != targetBinding.endpointID
                && $0.binding.bindingID != targetBinding.bindingID
        })
        if merged.count > Self.maximumTargetCount {
            merged.removeLast(merged.count - Self.maximumTargetCount)
        }
        let record = CmxIrohStoredClientPolicyRecord(
            version: CmxIrohStoredClientPolicyRecord.currentVersion,
            scopeDigest: Self.scopeDigest(for: expectation),
            localBinding: localBinding,
            relayFleet: discovery.relayFleet.sorted(),
            grantVerificationKeys: discovery.grantVerificationKeys,
            lanRendezvous: discovery.lanRendezvous,
            targets: merged
        )
        try await writeStoredRecord(
            JSONEncoder().encode(record),
            epoch: epoch
        )
        try requireCurrent(epoch)
    }

    /// Loads authority for exactly the requested, already-known Mac tuple.
    public func load(
        for request: CmxByteTransportRequest,
        localBinding: CmxIrohBrokerBinding,
        expectation: CmxIrohClientOfflinePolicyExpectation,
        confirmedDiscovery: CmxIrohDiscoveryResponse?,
        now: Date
    ) async throws -> CmxIrohCachedClientPolicy? {
        let epoch = try beginOperation()
        guard request.route.kind == .iroh,
              request.authorizationMode == .transportAdmission,
              let expectedDeviceID = request.expectedPeerDeviceID,
              case let .peer(expectedEndpointID, _) = request.route.endpoint else {
            try requireCurrent(epoch)
            return nil
        }
        guard var record = try await loadRecord(
            for: expectation,
            confirmedLocalBinding: localBinding,
            epoch: epoch
        ) else {
            try requireCurrent(epoch)
            return nil
        }
        try requireCurrent(epoch)

        let authority: (
            local: CmxIrohBrokerBinding,
            targets: [CmxIrohBrokerBinding],
            keys: CmxIrohGrantVerificationKeySet,
            lan: CmxIrohLANRendezvous
        )
        if let confirmedDiscovery {
            try validateDiscovery(confirmedDiscovery, for: expectation)
            let localMatches = confirmedDiscovery.bindings.filter {
                expectation.localBindingExpectation.matches($0)
                    && Self.sameAuthority($0, localBinding)
            }
            guard localMatches.count == 1, let confirmedLocal = localMatches.first else {
                try await deleteStoredRecord(epoch: epoch)
                try requireCurrent(epoch)
                return nil
            }
            authority = (
                confirmedLocal,
                confirmedDiscovery.bindings,
                confirmedDiscovery.grantVerificationKeys,
                confirmedDiscovery.lanRendezvous
            )
        } else {
            authority = (
                record.localBinding,
                record.targets.map(\.binding),
                record.grantVerificationKeys,
                record.lanRendezvous
            )
        }

        let originalCount = record.targets.count
        record = try reverifiedRecord(
            record,
            localBinding: authority.local,
            currentTargets: authority.targets,
            keys: authority.keys,
            lanRendezvous: authority.lan,
            now: now
        )
        if record.targets.count != originalCount || confirmedDiscovery != nil {
            try await persistOrDelete(record, epoch: epoch)
            try requireCurrent(epoch)
        }
        guard let stored = record.targets.first(where: {
            CmxIrohDeviceID($0.binding.deviceID)
                == CmxIrohDeviceID(expectedDeviceID)
                && $0.binding.endpointID == expectedEndpointID
        }) else {
            try requireCurrent(epoch)
            return nil
        }
        try requireCurrent(epoch)
        return CmxIrohCachedClientPolicy(
            localBinding: record.localBinding,
            targetBinding: stored.binding,
            pairGrant: stored.pairGrant,
            grantVerificationKeys: record.grantVerificationKeys,
            lanRendezvous: record.lanRendezvous
        )
    }

    /// Loads all still-signed known targets for connectivity-only runtime startup.
    public func loadBootstrap(
        for expectation: CmxIrohClientOfflinePolicyExpectation,
        confirmedLocalBinding: CmxIrohBrokerBinding?,
        now: Date
    ) async throws -> CmxIrohClientOfflineBootstrap? {
        let epoch = try beginOperation()
        guard var record = try await loadRecord(
            for: expectation,
            confirmedLocalBinding: confirmedLocalBinding,
            epoch: epoch
        ) else {
            try requireCurrent(epoch)
            return nil
        }
        try requireCurrent(epoch)
        let local = confirmedLocalBinding ?? record.localBinding
        record = try reverifiedRecord(
            record,
            localBinding: local,
            currentTargets: record.targets.map(\.binding),
            keys: record.grantVerificationKeys,
            lanRendezvous: record.lanRendezvous,
            now: now
        )
        try await persistOrDelete(record, epoch: epoch)
        try requireCurrent(epoch)
        guard !record.targets.isEmpty else {
            try requireCurrent(epoch)
            return nil
        }
        try requireCurrent(epoch)
        return CmxIrohClientOfflineBootstrap(
            localBinding: record.localBinding,
            targetBindings: record.targets.map(\.binding),
            lanRendezvous: record.lanRendezvous
        )
    }

    /// Removes every active-account client policy during account/app teardown.
    public func deactivate() async throws {
        lifecycleEpoch &+= 1
        deactivationCount += 1
        defer { deactivationCount -= 1 }
        await waitForStorageMutationsToDrain()
        try await secureStore.deleteAll()
    }

    private func loadRecord(
        for expectation: CmxIrohClientOfflinePolicyExpectation,
        confirmedLocalBinding: CmxIrohBrokerBinding?,
        epoch: UInt64
    ) async throws -> CmxIrohStoredClientPolicyRecord? {
        let storedData = try await secureStore.read(account: Self.storageAccount)
        try requireCurrent(epoch)
        guard let data = storedData else {
            try requireCurrent(epoch)
            return nil
        }
        do {
            let record = try JSONDecoder().decode(CmxIrohStoredClientPolicyRecord.self, from: data)
            guard record.version == CmxIrohStoredClientPolicyRecord.currentVersion,
                  record.scopeDigest == Self.scopeDigest(for: expectation),
                  record.targets.count <= Self.maximumTargetCount,
                  Set(record.relayFleet) == expectation.managedRelayURLs,
                  record.relayFleet.count == expectation.managedRelayURLs.count,
                  expectation.localBindingExpectation.matches(record.localBinding),
                  confirmedLocalBinding.map({
                      expectation.localBindingExpectation.matches($0)
                          && Self.sameAuthority($0, record.localBinding)
                  }) ?? true else {
                throw CmxIrohClientOfflinePolicyCacheError.policyMismatch
            }
            try requireCurrent(epoch)
            return record
        } catch {
            try await deleteStoredRecord(epoch: epoch)
            try requireCurrent(epoch)
            return nil
        }
    }

    private func reverifiedRecord(
        _ record: CmxIrohStoredClientPolicyRecord,
        localBinding: CmxIrohBrokerBinding,
        currentTargets: [CmxIrohBrokerBinding],
        keys: CmxIrohGrantVerificationKeySet,
        lanRendezvous: CmxIrohLANRendezvous,
        now: Date
    ) throws -> CmxIrohStoredClientPolicyRecord {
        var targets: [CmxIrohStoredClientPolicyTarget] = []
        for stored in record.targets {
            guard let current = Self.uniqueBinding(
                in: currentTargets,
                matchingAuthorityOf: stored.binding
            ),
                current.platform == .mac,
                current.pairingEnabled,
                (try? validateGrant(
                    stored.pairGrant,
                    localBinding: localBinding,
                    targetBinding: current,
                    keys: keys,
                    now: now
                )) != nil else {
                continue
            }
            targets.append(.init(binding: current, pairGrant: stored.pairGrant))
        }
        return CmxIrohStoredClientPolicyRecord(
            version: record.version,
            scopeDigest: record.scopeDigest,
            localBinding: localBinding,
            relayFleet: record.relayFleet,
            grantVerificationKeys: keys,
            lanRendezvous: lanRendezvous,
            targets: Array(targets.prefix(Self.maximumTargetCount))
        )
    }

    private func persistOrDelete(
        _ record: CmxIrohStoredClientPolicyRecord,
        epoch: UInt64
    ) async throws {
        try requireCurrent(epoch)
        guard !record.targets.isEmpty else {
            try await deleteStoredRecord(epoch: epoch)
            try requireCurrent(epoch)
            return
        }
        try await writeStoredRecord(
            JSONEncoder().encode(record),
            epoch: epoch
        )
        try requireCurrent(epoch)
    }

    private func beginOperation() throws -> UInt64 {
        try Task.checkCancellation()
        guard deactivationCount == 0 else { throw CancellationError() }
        return lifecycleEpoch
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard deactivationCount == 0, lifecycleEpoch == epoch else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func writeStoredRecord(_ data: Data, epoch: UInt64) async throws {
        try requireCurrent(epoch)
        activeStorageMutationCount += 1
        defer { finishStorageMutation() }
        try await secureStore.write(
            data,
            account: Self.storageAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        try requireCurrent(epoch)
    }

    private func deleteStoredRecord(epoch: UInt64) async throws {
        try requireCurrent(epoch)
        activeStorageMutationCount += 1
        defer { finishStorageMutation() }
        try await secureStore.delete(account: Self.storageAccount)
        try requireCurrent(epoch)
    }

    private func finishStorageMutation() {
        activeStorageMutationCount -= 1
        guard activeStorageMutationCount == 0 else { return }
        let waiters = storageMutationDrainWaiters
        storageMutationDrainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForStorageMutationsToDrain() async {
        guard activeStorageMutationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            storageMutationDrainWaiters.append(continuation)
        }
    }

    private func validateDiscovery(
        _ discovery: CmxIrohDiscoveryResponse,
        for expectation: CmxIrohClientOfflinePolicyExpectation
    ) throws {
        guard discovery.routeContractVersion == 1,
              discovery.relayFleet.count == expectation.managedRelayURLs.count,
              Set(discovery.relayFleet) == expectation.managedRelayURLs else {
            throw CmxIrohClientOfflinePolicyCacheError.invalidPolicy
        }
    }

    private func validateGrant(
        _ response: CmxIrohPairGrantResponse,
        localBinding: CmxIrohBrokerBinding,
        targetBinding: CmxIrohBrokerBinding,
        keys: CmxIrohGrantVerificationKeySet,
        now: Date
    ) throws {
        let claims = try verifier.verifyPairGrant(
            response.grant,
            keys: keys,
            initiator: CmxIrohGrantPeer(binding: localBinding),
            acceptor: CmxIrohGrantPeer(binding: targetBinding),
            now: now
        )
        let signedExpiry = Date(timeIntervalSince1970: TimeInterval(claims.expiresAt))
        guard let envelopeExpiry = CmxIrohISO8601Date.parse(response.expiresAt),
              abs(envelopeExpiry.timeIntervalSince(signedExpiry)) < 1,
              envelopeExpiry > now else {
            throw CmxIrohClientOfflinePolicyCacheError.invalidGrantEnvelope
        }
    }

    private static func uniqueBinding(
        in bindings: [CmxIrohBrokerBinding],
        matchingAuthorityOf expected: CmxIrohBrokerBinding
    ) -> CmxIrohBrokerBinding? {
        let matches = bindings.filter { sameAuthority($0, expected) }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func sameAuthority(
        _ left: CmxIrohBrokerBinding,
        _ right: CmxIrohBrokerBinding
    ) -> Bool {
        left.bindingID == right.bindingID
            && left.deviceID == right.deviceID
            && left.appInstanceID == right.appInstanceID
            && left.tag == right.tag
            && left.platform == right.platform
            && left.endpointID == right.endpointID
            && left.identityGeneration == right.identityGeneration
            && left.pairingEnabled == right.pairingEnabled
            && left.capabilities.count == right.capabilities.count
            && Set(left.capabilities) == Set(right.capabilities)
    }

    private static func scopeDigest(
        for expectation: CmxIrohClientOfflinePolicyExpectation
    ) -> String {
        let transcript = Data(
            "cmux/iroh/offline-client-policy-scope/v1\0\(expectation.accountID)\0\(expectation.localBindingExpectation.appInstanceID)".utf8
        )
        return SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}
