import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

private actor RefreshBootstrapBroker: CmxIrohRelayPolicyServing {
    private let bootstrap: CmxIrohRelayBootstrapResponse
    private(set) var bootstrapRequestCount = 0

    init(bootstrap: CmxIrohRelayBootstrapResponse) {
        self.bootstrap = bootstrap
    }

    func issueRelayBootstrap(
        endpointID _: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse {
        bootstrapRequestCount += 1
        return bootstrap
    }

    func relayPreference() async throws -> CmxIrohRelayPreferenceResponse {
        throw CmxIrohRelayPolicyServiceError.brokerUnavailable
    }

    func updateRelayPreference(
        _: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse {
        throw CmxIrohRelayPolicyServiceError.brokerUnavailable
    }
}

@Suite
struct CmxIrohRelayPolicyServiceRefreshTests {
    @Test
    func refreshWithCredentialReturnsMintedCredentialWithEffectivePolicy() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let credential = fixture.relayCredential()
        let broker = RefreshBootstrapBroker(
            bootstrap: CmxIrohRelayBootstrapResponse(
                relayToken: credential,
                relayPolicy: try CmxIrohRelayPolicyResponse(
                    policy: fixture.token(sequence: 1),
                    preference: .automatic,
                    preferenceRevision: 1
                )
            )
        )
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore()),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            ),
            broker: broker
        )

        let outcome = try await service.refreshWithCredential(
            endpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "a", count: 64)
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )

        #expect(outcome.relayCredential == credential)
        #expect(outcome.effective.endpointRelayProfile.allowedRelayURLs
            == Set(fixture.relayURLs))
        #expect(await broker.bootstrapRequestCount == 1)
    }

    @Test
    func refreshDelegatesToRefreshWithCredential() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let broker = RefreshBootstrapBroker(
            bootstrap: CmxIrohRelayBootstrapResponse(
                relayToken: nil,
                relayPolicy: try CmxIrohRelayPolicyResponse(
                    policy: fixture.token(sequence: 1),
                    preference: .automatic,
                    preferenceRevision: 1
                )
            )
        )
        let service = CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore()),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            ),
            broker: broker
        )

        let effective = try await service.refresh(
            endpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "b", count: 64)
            ),
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )

        #expect(effective.endpointRelayProfile.allowedRelayURLs == Set(fixture.relayURLs))
        #expect(await broker.bootstrapRequestCount == 1)
    }
}
