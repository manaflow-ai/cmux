import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh offline host policy cache")
struct CmxIrohHostPolicyCacheTests {
    @Test("verified policy survives cache recreation in device-only Keychain storage")
    func roundTripsVerifiedPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let policy = try fixture.policy()
        let cache = CmxIrohHostPolicyCache(secureStore: store)

        try await cache.save(policy, for: expectation, now: fixture.now)

        let recreated = CmxIrohHostPolicyCache(secureStore: store)
        #expect(
            try await recreated.load(for: expectation, now: fixture.now) == policy
        )
        #expect(
            try await recreated.load(for: expectation, now: fixture.now)?.lanRendezvous
                == fixture.lanRendezvous
        )
        #expect(
            await store.observedAccessibilities()
                == [.afterFirstUnlockThisDeviceOnly]
        )
    }

    @Test("save verifies the attestation before replacing cached authority")
    func saveRejectsWrongSigningKey() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let cache = CmxIrohHostPolicyCache(secureStore: store)

        await #expect(throws: CmxIrohGrantVerifierError.invalidSignature) {
            try await cache.save(
                fixture.policySignedByOriginalKey(
                    publishedKeySet: fixture.alternateKeySet
                ),
                for: expectation,
                now: fixture.now
            )
        }
        #expect(await store.recordCount() == 0)
    }

    @Test("save rejects an already expired signed attestation")
    func saveRejectsExpiredPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let cache = CmxIrohHostPolicyCache(secureStore: store)

        await #expect(throws: CmxIrohGrantVerifierError.expired) {
            try await cache.save(
                fixture.policy(
                    expiresAt: fixture.now.addingTimeInterval(-1)
                ),
                for: expectation,
                now: fixture.now
            )
        }
        #expect(await store.recordCount() == 0)
    }

    @Test("expired policy is deleted and returned as a cache miss")
    func loadDeletesExpiredPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: expectation,
            now: fixture.now
        )

        #expect(
            try await cache.load(
                for: expectation,
                now: fixture.now.addingTimeInterval(3_601)
            ) == nil
        )
        #expect(await store.recordCount() == 0)
    }

    @Test("wrong account deletes the active policy instead of resurrecting it")
    func loadDeletesWrongAccountPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: fixture.expectation(),
            now: fixture.now
        )

        #expect(
            try await cache.load(
                for: fixture.expectation(accountID: "account-b"),
                now: fixture.now
            ) == nil
        )
        #expect(await store.recordCount() == 0)
    }

    @Test("wrong app instance deletes the active policy")
    func loadDeletesWrongAppInstancePolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: fixture.expectation(),
            now: fixture.now
        )

        #expect(
            try await cache.load(
                for: fixture.expectation(
                    appInstanceID: "123e4567-e89b-42d3-a456-426614174088"
                ),
                now: fixture.now
            ) == nil
        )
        #expect(await store.recordCount() == 0)
    }

    @Test("wrong identity generation deletes the active policy")
    func loadDeletesWrongGenerationPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: fixture.expectation(),
            now: fixture.now
        )

        #expect(
            try await cache.load(
                for: fixture.expectation(identityGeneration: 5),
                now: fixture.now
            ) == nil
        )
        #expect(await store.recordCount() == 0)
    }

    @Test("wrong local EndpointID deletes the active policy")
    func loadDeletesWrongEndpointPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: fixture.expectation(),
            now: fixture.now
        )

        #expect(
            try await cache.load(
                for: fixture.expectation(
                    endpointID: CmxIrohPeerIdentity(
                        endpointID: String(repeating: "cd", count: 32)
                    )
                ),
                now: fixture.now
            ) == nil
        )
        #expect(await store.recordCount() == 0)
    }

    @Test("changed pairing policy deletes the active policy")
    func loadDeletesChangedPairingPolicy() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: fixture.expectation(),
            now: fixture.now
        )

        #expect(
            try await cache.load(
                for: fixture.expectation(pairingEnabled: false),
                now: fixture.now
            ) == nil
        )
        #expect(await store.recordCount() == 0)
    }

    @Test("wrong cached verification keyset is deleted")
    func loadDeletesWrongVerificationKeySet() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: expectation,
            now: fixture.now
        )
        let account = try #require(await store.lastDeletedOrWrittenAccount())
        let encoded = try #require(await store.read(account: account))
        let corrupted = try replacingKeySets(
            in: encoded,
            with: fixture.alternateKeySet
        )
        await store.seed(corrupted, account: account)

        #expect(try await cache.load(for: expectation, now: fixture.now) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("corrupt records are deleted and returned as a cache miss")
    func loadDeletesCorruptRecord() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: expectation,
            now: fixture.now
        )
        let account = try #require(await store.lastDeletedOrWrittenAccount())
        await store.seed(Data("not-json".utf8), account: account)

        #expect(try await cache.load(for: expectation, now: fixture.now) == nil)
        #expect(await store.recordCount() == 0)
    }

    @Test("scoped deletion and deactivation remove cached policy")
    func explicitDeletion() async throws {
        let fixture = try HostPolicyCacheTestFixture()
        let store = TestSecureCredentialStore()
        let expectation = try fixture.expectation()
        let cache = CmxIrohHostPolicyCache(secureStore: store)
        try await cache.save(
            fixture.policy(),
            for: expectation,
            now: fixture.now
        )

        try await cache.delete(for: expectation)
        #expect(await store.recordCount() == 0)

        try await cache.save(
            fixture.policy(),
            for: expectation,
            now: fixture.now
        )
        try await cache.deactivate()
        #expect(await store.recordCount() == 0)
        #expect(await store.deleteAllCount() == 1)
    }

    private func replacingKeySets(
        in data: Data,
        with keySet: CmxIrohGrantVerificationKeySet
    ) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var policy = try #require(root["policy"] as? [String: Any])
        let encodedKeySet = try JSONEncoder().encode(keySet)
        let keySetObject = try JSONSerialization.jsonObject(with: encodedKeySet)
        policy["grantVerificationKeys"] = keySetObject
        var attestation = try #require(
            policy["endpointAttestation"] as? [String: Any]
        )
        attestation["grant_verification_keys"] = keySetObject
        policy["endpointAttestation"] = attestation
        root["policy"] = policy
        return try JSONSerialization.data(withJSONObject: root)
    }
}
