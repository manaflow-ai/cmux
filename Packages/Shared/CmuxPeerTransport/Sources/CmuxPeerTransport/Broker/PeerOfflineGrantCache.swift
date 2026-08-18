public import CMUXMobileCore
public import Foundation
import CryptoKit

/// Stores signed pair grants for connectivity-only offline fallback.
///
/// Scope: one record per (account, app instance, local endpoint
/// identity/generation, managed relay fleet). Grants are reverified against
/// the stored verification key set and their signed expiry on every load, and
/// the cache may be consulted ONLY after a broker connectivity failure —
/// authentication, denial, and protocol failures fail closed by construction.
/// Sign-out or account switch deletes it via ``deactivate()``.
///
/// The Keychain service, account, and record JSON are unchanged from the
/// previous transport, so grants cached before the engine swap stay usable.
public actor PeerOfflineGrantCache {
    /// The generic-password service the previous transport used.
    public static let keychainService = "com.cmuxterm.iroh.client-offline-policy.v1"
    private static let storageAccount = "active-client-policies"

    private let secureStore: any PeerSecureBlobStoring
    private let verifier: PeerGrantVerifier
    private var lifecycleEpoch: UInt64 = 0
    private var deactivationCount = 0
    private var activeStorageMutationCount = 0
    private var storageMutationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        secureStore: any PeerSecureBlobStoring = PeerIdentityStore(
            service: PeerOfflineGrantCache.keychainService
        ),
        verifier: PeerGrantVerifier = PeerGrantVerifier()
    ) {
        self.secureStore = secureStore
        self.verifier = verifier
    }

    /// Merges one online-verified target into the active-account cache.
    ///
    /// Every input is validated against the fresh discovery snapshot that
    /// proved it: the local binding must be the expectation's unique row, the
    /// target must be a unique pairable Mac, and the grant must verify against
    /// the snapshot's key set with a consistent envelope expiry.
    public func save(
        localBinding: PeerBrokerBinding,
        targetBinding: PeerBrokerBinding,
        discovery: PeerBrokerDiscoverySnapshot,
        pairGrant: PeerPairGrantResponse,
        for expectation: PeerOfflineGrantExpectation,
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
            throw PeerOfflineGrantCacheError.invalidPolicy
        }
        try validateGrant(
            pairGrant,
            localBinding: localBinding,
            targetBinding: targetBinding,
            keys: discovery.grantVerificationKeys,
            now: now
        )

        // Retain previously cached targets that still verify against the
        // fresh snapshot's bindings and keys; drop the rest.
        var retained: [PeerStoredGrantTarget] = []
        let readResult = await secureStore.read(account: Self.storageAccount)
        try requireCurrent(epoch)
        if case let .found(data) = readResult,
           let record = try? JSONDecoder().decode(PeerStoredGrantRecord.self, from: data),
           record.version == PeerStoredGrantRecord.currentVersion,
           record.scopeDigest == Self.scopeDigest(for: expectation),
           record.localBinding.sameAuthority(as: localBinding) {
            let index = Self.bindingAuthorityIndex(discovery.bindings)
            for stored in record.targets {
                guard let fresh = Self.uniqueBinding(
                    in: index,
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

        var merged = [PeerStoredGrantTarget(binding: targetBinding, pairGrant: pairGrant)]
        merged.append(contentsOf: retained.filter {
            $0.binding.endpointID != targetBinding.endpointID
                && $0.binding.bindingID != targetBinding.bindingID
        })
        let record = PeerStoredGrantRecord(
            version: PeerStoredGrantRecord.currentVersion,
            scopeDigest: Self.scopeDigest(for: expectation),
            localBinding: localBinding,
            relayFleet: discovery.relayFleet.sorted(),
            grantVerificationKeys: discovery.grantVerificationKeys,
            lanRendezvous: discovery.lanRendezvous,
            targets: merged
        )
        try await writeStoredRecord(JSONEncoder().encode(record), epoch: epoch)
        try requireCurrent(epoch)
    }

    /// Loads authority for exactly the requested, already-known Mac tuple.
    ///
    /// `brokerFailure` is the failure that made the caller fall back. Anything
    /// other than ``PeerBrokerError/connectivity`` returns nil WITHOUT reading
    /// storage: auth and protocol failures fail closed, and they never delete
    /// the cache either (only ``deactivate()`` does).
    public func load(
        afterBrokerFailure brokerFailure: PeerBrokerError,
        targetDeviceID: String,
        targetEndpointID: CmxIrohPeerIdentity,
        expectation: PeerOfflineGrantExpectation,
        confirmedLocalBinding: PeerBrokerBinding?,
        now: Date
    ) async throws -> PeerCachedGrantAuthority? {
        guard brokerFailure.allowsOfflineGrantFallback else {
            return nil
        }
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

        // Offline by definition: reverify against the stored authority.
        let originalCount = record.targets.count
        record = reverifiedRecord(record, now: now)
        if record.targets.count != originalCount {
            try await persistOrDelete(record, epoch: epoch)
            try requireCurrent(epoch)
        }
        guard let stored = record.targets.first(where: {
            cmxCanonicalDeviceID($0.binding.deviceID)
                == cmxCanonicalDeviceID(targetDeviceID)
                && $0.binding.endpointID == targetEndpointID
        }) else {
            try requireCurrent(epoch)
            return nil
        }
        try requireCurrent(epoch)
        return PeerCachedGrantAuthority(
            localBinding: record.localBinding,
            targetBinding: stored.binding,
            pairGrant: stored.pairGrant,
            grantVerificationKeys: record.grantVerificationKeys,
            lanRendezvous: record.lanRendezvous
        )
    }

    /// Removes every cached grant during sign-out or account switch.
    public func deactivate() async throws {
        lifecycleEpoch &+= 1
        deactivationCount += 1
        defer { deactivationCount -= 1 }
        await waitForStorageMutationsToDrain()
        try await secureStore.deleteAll()
    }

    private func loadRecord(
        for expectation: PeerOfflineGrantExpectation,
        confirmedLocalBinding: PeerBrokerBinding?,
        epoch: UInt64
    ) async throws -> PeerStoredGrantRecord? {
        let readResult = await secureStore.read(account: Self.storageAccount)
        try requireCurrent(epoch)
        guard case let .found(data) = readResult else {
            // `.absent` has no record; `.unavailable` must not be treated as
            // absent, but the fallback simply is not available right now.
            // Neither deletes anything.
            return nil
        }
        do {
            let record = try JSONDecoder().decode(PeerStoredGrantRecord.self, from: data)
            guard record.version == PeerStoredGrantRecord.currentVersion,
                  record.scopeDigest == Self.scopeDigest(for: expectation),
                  Set(record.relayFleet) == expectation.managedRelayURLs,
                  record.relayFleet.count == expectation.managedRelayURLs.count,
                  expectation.localBindingExpectation.matches(record.localBinding),
                  confirmedLocalBinding.map({
                      expectation.localBindingExpectation.matches($0)
                          && $0.sameAuthority(as: record.localBinding)
                  }) ?? true else {
                throw PeerOfflineGrantCacheError.policyMismatch
            }
            try requireCurrent(epoch)
            return record
        } catch {
            // Undecodable or out-of-scope state is useless and unsafe to keep.
            try await deleteStoredRecord(epoch: epoch)
            try requireCurrent(epoch)
            return nil
        }
    }

    private func reverifiedRecord(
        _ record: PeerStoredGrantRecord,
        now: Date
    ) -> PeerStoredGrantRecord {
        var targets: [PeerStoredGrantTarget] = []
        for stored in record.targets {
            guard stored.binding.platform == .mac,
                  stored.binding.pairingEnabled,
                  (try? validateGrant(
                      stored.pairGrant,
                      localBinding: record.localBinding,
                      targetBinding: stored.binding,
                      keys: record.grantVerificationKeys,
                      now: now
                  )) != nil else {
                continue
            }
            targets.append(stored)
        }
        return PeerStoredGrantRecord(
            version: record.version,
            scopeDigest: record.scopeDigest,
            localBinding: record.localBinding,
            relayFleet: record.relayFleet,
            grantVerificationKeys: record.grantVerificationKeys,
            lanRendezvous: record.lanRendezvous,
            targets: targets
        )
    }

    private func persistOrDelete(
        _ record: PeerStoredGrantRecord,
        epoch: UInt64
    ) async throws {
        try requireCurrent(epoch)
        guard !record.targets.isEmpty else {
            try await deleteStoredRecord(epoch: epoch)
            try requireCurrent(epoch)
            return
        }
        try await writeStoredRecord(JSONEncoder().encode(record), epoch: epoch)
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
        try await secureStore.write(data, account: Self.storageAccount)
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
        _ discovery: PeerBrokerDiscoverySnapshot,
        for expectation: PeerOfflineGrantExpectation
    ) throws {
        guard discovery.routeContractVersion == 1,
              discovery.relayFleet.count == expectation.managedRelayURLs.count,
              Set(discovery.relayFleet) == expectation.managedRelayURLs else {
            throw PeerOfflineGrantCacheError.invalidPolicy
        }
    }

    private func validateGrant(
        _ response: PeerPairGrantResponse,
        localBinding: PeerBrokerBinding,
        targetBinding: PeerBrokerBinding,
        keys: PeerGrantVerificationKeySet,
        now: Date
    ) throws {
        let claims = try verifier.verifyPairGrant(
            response.grant,
            keys: keys,
            initiator: PeerGrantPeer(binding: localBinding),
            acceptor: PeerGrantPeer(binding: targetBinding),
            now: now
        )
        let signedExpiry = Date(timeIntervalSince1970: TimeInterval(claims.expiresAt))
        guard let envelopeExpiry = PeerBrokerWire.parseISO8601(response.expiresAt),
              abs(envelopeExpiry.timeIntervalSince(signedExpiry)) < 1,
              envelopeExpiry > now else {
            throw PeerOfflineGrantCacheError.invalidGrantEnvelope
        }
    }

    private static func bindingAuthorityIndex(
        _ bindings: [PeerBrokerBinding]
    ) -> (byBindingID: [String: PeerBrokerBinding], duplicateBindingIDs: Set<String>) {
        var byBindingID: [String: PeerBrokerBinding] = [:]
        var duplicateBindingIDs: Set<String> = []
        for binding in bindings {
            if byBindingID.updateValue(binding, forKey: binding.bindingID) != nil {
                duplicateBindingIDs.insert(binding.bindingID)
            }
        }
        return (byBindingID, duplicateBindingIDs)
    }

    private static func uniqueBinding(
        in index: (byBindingID: [String: PeerBrokerBinding], duplicateBindingIDs: Set<String>),
        matchingAuthorityOf expected: PeerBrokerBinding
    ) -> PeerBrokerBinding? {
        guard !index.duplicateBindingIDs.contains(expected.bindingID),
              let binding = index.byBindingID[expected.bindingID],
              binding.sameAuthority(as: expected) else {
            return nil
        }
        return binding
    }

    private static func scopeDigest(for expectation: PeerOfflineGrantExpectation) -> String {
        let transcript = Data(
            "cmux/iroh/offline-client-policy-scope/v2\0\(expectation.accountID)\0\(expectation.localBindingExpectation.clientNamespace)\0\(expectation.localBindingExpectation.appInstanceID)".utf8
        )
        return PeerBrokerWire.hex(Data(SHA256.hash(data: transcript)))
    }
}
