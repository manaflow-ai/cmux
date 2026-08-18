import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxPeerTransport

@Suite struct PeerRelayTokenServingTests {
    private struct FixtureBroker: PeerRelayTokenServing {
        let grant: PeerRelayTokenGrant

        func mintRelayCredential(
            endpointID: CmxIrohPeerIdentity
        ) async throws -> PeerRelayTokenGrant {
            grant
        }
    }

    @Test func mintedGrantFlowsThroughVerificationIntoAPlan() async throws {
        let signer = PeerRelayPolicySigner()
        let broker = FixtureBroker(
            grant: PeerRelayTokenGrant(
                credential: signer.mintedResponse(),
                signedPolicy: try signer.token(sequence: 7)
            )
        )
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )

        let grant = try await broker.mintRelayCredential(endpointID: endpointID)
        let cache = PeerRelayPolicyCache(store: InMemoryRelayPolicyStore())
        let policy = try await cache.install(
            signedPolicy: try #require(grant.signedPolicy),
            trustRoot: signer.trustRoot(),
            now: signer.now
        )
        let plan = try PeerRelayCredentialPlan(
            policy: policy,
            minted: grant.credential,
            now: signer.now,
            jitter: PeerRelayRefreshJitter { 0 }
        )

        #expect(plan.configs.map(\.url) == signer.relayURLs)
        #expect(plan.schedule.refreshDeadline <= plan.schedule.refreshAfter)
        #expect(plan.schedule.refreshDeadline < plan.schedule.expiresAt)
    }
}
