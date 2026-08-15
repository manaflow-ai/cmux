import CryptoKit
public import Foundation

/// Stores one active account's cryptographically verified offline Mac host policy.
public actor CmxIrohHostPolicyCache {
    private static let storageAccount = "active-host-policy"

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let verifier: CmxIrohGrantVerifier
    private var lifecycleEpoch: UInt64 = 0
    private var deactivationCount = 0
    private var activeStorageMutationCount = 0
    private var storageMutationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a cache with injectable secure storage and signature verification.
    ///
    /// The production default uses a Keychain service distinct from relay
    /// credentials with `AfterFirstUnlockThisDeviceOnly` data protection.
    ///
    /// - Parameters:
    ///   - secureStore: The secure persistence boundary for the single active policy.
    ///   - verifier: The broker Ed25519 grant and attestation verifier.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.host-policy.v1"
        ),
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier()
    ) {
        self.secureStore = secureStore
        self.verifier = verifier
    }

    /// Saves a policy only after verifying its signature, exact tuple, and expiry.
    ///
    /// A failed validation removes the active cache entry so a previously cached
    /// policy cannot survive an identity or account transition.
    ///
    /// - Parameters:
    ///   - policy: The broker policy candidate to validate and persist.
    ///   - expectation: The current local account, identity, and host settings.
    ///   - now: The validation time.
    /// - Throws: A policy, attestation, encoding, or secure-storage error.
    public func save(
        _ policy: CmxIrohCachedHostPolicy,
        for expectation: CmxIrohHostPolicyExpectation,
        now: Date
    ) async throws {
        let epoch = try beginOperation()
        do {
            try validate(policy, for: expectation, now: now)
        } catch {
            try await deleteSecureRecord(epoch: epoch)
            throw error
        }
        let record = CmxIrohStoredHostPolicyRecord(
            scopeDigest: Self.scopeDigest(for: expectation),
            policy: policy
        )
        let data = try JSONEncoder().encode(record)
        try await writeSecureRecord(
            data,
            epoch: epoch
        )
    }

    /// Loads a policy only when it still verifies for the current local state.
    ///
    /// Corrupt, expired, wrong-account, wrong-app-instance, wrong-generation,
    /// wrong-keyset, and settings-mismatched entries are deleted and returned as
    /// a cache miss. A verified result is an offline fallback only; callers must
    /// replace it with fresh authenticated broker policy when online.
    ///
    /// - Parameters:
    ///   - expectation: The current local account, identity, and host settings.
    ///   - now: The validation time.
    /// - Returns: The verified fallback policy, or `nil` when online registration is required.
    /// - Throws: A secure-storage error when the invalid entry cannot be read or deleted.
    public func load(
        for expectation: CmxIrohHostPolicyExpectation,
        now: Date
    ) async throws -> CmxIrohCachedHostPolicy? {
        let epoch = try beginOperation()
        guard let data = try await readSecureRecord(epoch: epoch) else {
            return nil
        }
        do {
            let record = try JSONDecoder().decode(
                CmxIrohStoredHostPolicyRecord.self,
                from: data
            )
            guard record.version == CmxIrohStoredHostPolicyRecord.currentVersion,
                  record.scopeDigest == Self.scopeDigest(for: expectation) else {
                throw CmxIrohHostPolicyCacheError.policyMismatch
            }
            try validate(record.policy, for: expectation, now: now)
            try requireCurrent(epoch)
            return record.policy
        } catch {
            if error is CancellationError { throw error }
            try await deleteSecureRecord(epoch: epoch)
            return nil
        }
    }

    /// Deletes the active policy when it belongs to the supplied account scope.
    ///
    /// A corrupt envelope is also deleted because its ownership cannot be proven.
    ///
    /// - Parameter expectation: The current account and app-instance scope.
    /// - Throws: A secure-storage error.
    public func delete(for expectation: CmxIrohHostPolicyExpectation) async throws {
        let epoch = try beginOperation()
        guard let data = try await readSecureRecord(epoch: epoch) else {
            return
        }
        guard let record = try? JSONDecoder().decode(
            CmxIrohStoredHostPolicyRecord.self,
            from: data
        ) else {
            try await deleteSecureRecord(epoch: epoch)
            return
        }
        guard record.scopeDigest == Self.scopeDigest(for: expectation) else {
            return
        }
        try await deleteSecureRecord(epoch: epoch)
    }

    /// Removes every host-policy cache entry during sign-out or app-instance revocation.
    ///
    /// - Throws: A secure-storage error.
    public func deactivate() async throws {
        lifecycleEpoch &+= 1
        deactivationCount += 1
        defer { deactivationCount -= 1 }
        await waitForStorageMutations()
        try await secureStore.deleteAll()
    }

    private func beginOperation() throws -> UInt64 {
        guard deactivationCount == 0 else { throw CancellationError() }
        return lifecycleEpoch
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard deactivationCount == 0,
              lifecycleEpoch == epoch else { throw CancellationError() }
    }

    private func readSecureRecord(epoch: UInt64) async throws -> Data? {
        try requireCurrent(epoch)
        let data = try await secureStore.read(account: Self.storageAccount)
        try requireCurrent(epoch)
        return data
    }

    private func writeSecureRecord(_ data: Data, epoch: UInt64) async throws {
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

    private func deleteSecureRecord(epoch: UInt64) async throws {
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
        for waiter in waiters { waiter.resume() }
    }

    private func waitForStorageMutations() async {
        guard activeStorageMutationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            storageMutationDrainWaiters.append(continuation)
        }
    }

    private func validate(
        _ policy: CmxIrohCachedHostPolicy,
        for expectation: CmxIrohHostPolicyExpectation,
        now: Date
    ) throws {
        let binding = policy.binding
        guard binding.deviceID == expectation.deviceID,
              binding.appInstanceID == expectation.appInstanceID,
              binding.tag == expectation.tag,
              binding.platform == .mac,
              binding.endpointID == expectation.endpointID,
              binding.identityGeneration == expectation.identityGeneration,
              policy.pairingEnabled == expectation.pairingEnabled,
              policy.capabilities.count == expectation.capabilities.count,
              Set(policy.capabilities) == Set(expectation.capabilities),
              policy.endpointAttestation.attestationVersion == 1,
              policy.endpointAttestation.grantVerificationKeys
                  == policy.grantVerificationKeys else {
            throw CmxIrohHostPolicyCacheError.policyMismatch
        }
        let claims = try verifier.verifyEndpointAttestation(
            policy.endpointAttestation.attestation,
            keys: policy.grantVerificationKeys,
            expected: CmxIrohEndpointExpectation(
                bindingID: binding.bindingID,
                deviceID: binding.deviceID,
                endpointID: binding.endpointID,
                identityGeneration: binding.identityGeneration,
                platform: binding.platform
            ),
            now: now
        )
        guard let envelopeExpiry = CmxIrohISO8601Date.parse(
            policy.endpointAttestation.expiresAt
        ),
            let envelopeExpirySeconds = Self.seconds(envelopeExpiry),
            envelopeExpirySeconds == claims.expiresAt,
            envelopeExpiry > now else {
            throw CmxIrohHostPolicyCacheError.invalidAttestationEnvelope
        }
    }

    private static func scopeDigest(
        for expectation: CmxIrohHostPolicyExpectation
    ) -> String {
        let transcript = Data(
            "cmux/iroh/offline-host-policy-scope/v1\0\(expectation.accountID)\0\(expectation.appInstanceID)".utf8
        )
        return SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func seconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= TimeInterval(Int64.min),
              value <= TimeInterval(Int64.max) else {
            return nil
        }
        return Int64(value.rounded(.down))
    }
}
