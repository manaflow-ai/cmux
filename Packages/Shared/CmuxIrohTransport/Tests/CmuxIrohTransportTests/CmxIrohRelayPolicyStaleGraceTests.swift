import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

// Regression coverage for the policy-endpoint outage leg of
// https://github.com/manaflow-ai/cmux/issues/10375: when the relay-policy
// endpoint is unreachable and the cached signed policy passes its expiry,
// restore() used to strip relay authority, every dial plan assembled empty,
// and the phone sat on "Reconnecting" until a refresh finally succeeded
// (151s in field logs). A bounded staleness grace keeps the last VERIFIED
// relay list authoritative for dial-plan membership; signature, shape, and
// rollback checks still run (re-verified as of one second before the
// policy's own expiry), and the relay credential's independent expiry
// remains the hard authorization floor.
@Suite
struct CmxIrohRelayPolicyStaleGraceTests {
    private let grace: TimeInterval = 24 * 60 * 60

    @Test
    func cacheLoadHonorsBoundedStaleGraceAfterExpiry() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let cache = CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore())
        let expiresAt = Int64(fixture.now.timeIntervalSince1970) + 3_600
        _ = try await cache.install(
            signedPolicy: fixture.token(sequence: 1, expiresAt: expiresAt),
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )
        let justExpired = Date(timeIntervalSince1970: TimeInterval(expiresAt) + 60)

        // Strict expiry stays the default.
        await #expect(throws: CmxIrohRelayPolicyError.expired) {
            _ = try await cache.load(
                trustRoot: fixture.firstTrustRoot,
                now: justExpired
            )
        }
        // Within the grace window the verified policy remains loadable.
        let graced = try await cache.load(
            trustRoot: fixture.firstTrustRoot,
            now: justExpired,
            staleGrace: grace
        )
        #expect(graced?.relays.map(\.url) == fixture.relayURLs)
        // Beyond the grace window expiry is enforced again.
        await #expect(throws: CmxIrohRelayPolicyError.expired) {
            _ = try await cache.load(
                trustRoot: fixture.firstTrustRoot,
                now: Date(timeIntervalSince1970: TimeInterval(expiresAt) + grace + 1),
                staleGrace: grace
            )
        }
    }

    private func makeService() -> CmxIrohRelayPolicyService {
        CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore()),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            )
        )
    }

    @Test
    func restoreKeepsRelayAuthorityThroughAnOutageWithinGrace() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let service = makeService()
        let expiresAt = Int64(fixture.now.timeIntervalSince1970) + 3_600
        let response = try CmxIrohRelayPolicyResponse(
            policy: fixture.token(sequence: 1, expiresAt: expiresAt),
            preference: .automatic,
            preferenceRevision: 1
        )
        _ = try await service.install(
            response: response,
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            relayCredential: fixture.relayCredential(),
            now: fixture.now
        )
        let duringOutage = Date(timeIntervalSince1970: TimeInterval(expiresAt) + 120)

        // Old behavior (no grace): relay authority is stripped at expiry and
        // every relay-only dial plan assembles empty.
        let stripped = await service.restore(
            accountID: "account-a",
            trustRoot: try fixture.firstTrustRoot,
            now: duringOutage
        )
        #expect(stripped.endpointRelayProfile.allowedRelayURLs.isEmpty)

        // With the outage grace the last verified relay list stays effective.
        let graced = await service.restore(
            accountID: "account-a",
            trustRoot: try fixture.firstTrustRoot,
            now: duringOutage,
            staleGrace: grace
        )
        #expect(graced.endpointRelayProfile.allowedRelayURLs == Set(fixture.relayURLs))
        #expect(Set(graced.managedPolicy?.relays.map(\.url) ?? []) == Set(fixture.relayURLs))
    }
}
