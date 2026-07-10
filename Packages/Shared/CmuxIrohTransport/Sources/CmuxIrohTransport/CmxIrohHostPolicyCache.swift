import CryptoKit
public import Foundation

/// Stores one active account's cryptographically verified offline Mac host policy.
public actor CmxIrohHostPolicyCache {
    private static let storageAccount = "active-host-policy"

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let verifier: CmxIrohGrantVerifier

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
        do {
            try validate(policy, for: expectation, now: now)
        } catch {
            try await secureStore.delete(account: Self.storageAccount)
            throw error
        }
        let record = CmxIrohStoredHostPolicyRecord(
            scopeDigest: Self.scopeDigest(for: expectation),
            policy: policy
        )
        let data = try JSONEncoder().encode(record)
        try await secureStore.write(
            data,
            account: Self.storageAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
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
        guard let data = try await secureStore.read(account: Self.storageAccount) else {
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
            return record.policy
        } catch {
            try await secureStore.delete(account: Self.storageAccount)
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
        guard let data = try await secureStore.read(account: Self.storageAccount) else {
            return
        }
        guard let record = try? JSONDecoder().decode(
            CmxIrohStoredHostPolicyRecord.self,
            from: data
        ) else {
            try await secureStore.delete(account: Self.storageAccount)
            return
        }
        guard record.scopeDigest == Self.scopeDigest(for: expectation) else {
            return
        }
        try await secureStore.delete(account: Self.storageAccount)
    }

    /// Removes every host-policy cache entry during sign-out or app-instance revocation.
    ///
    /// - Throws: A secure-storage error.
    public func deactivate() async throws {
        try await secureStore.deleteAll()
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
        guard let envelopeExpiry = Self.date(
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

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
