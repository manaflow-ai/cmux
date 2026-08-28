import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

private actor RefreshPolicyBroker: CmxIrohRelayPolicyServing {
    private let response: CmxIrohRelayPolicyResponse
    private(set) var policyRequestCount = 0

    init(response: CmxIrohRelayPolicyResponse) {
        self.response = response
    }

    func fetchRelayPolicy() async throws -> CmxIrohRelayPolicyResponse {
        policyRequestCount += 1
        return response
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
    /// A refresh installs the signed policy and yields a tokenless managed
    /// profile: every allowed relay is active with no client credential,
    /// because relay admission is the relay's server-side allow hook.
    @Test
    func refreshInstallsTokenlessManagedProfile() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let broker = RefreshPolicyBroker(
            response: try CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: .automatic,
                preferenceRevision: 1
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
            accountID: "account-a",
            trustRoot: fixture.firstTrustRoot,
            now: fixture.now
        )

        #expect(effective.endpointRelayProfile.allowedRelayURLs == Set(fixture.relayURLs))
        #expect(effective.endpointRelayProfile.activeRelays.count == fixture.relayURLs.count)
        #expect(effective.endpointRelayProfile.activeRelays.allSatisfy {
            $0.authenticationToken == nil
        })
        #expect(await broker.policyRequestCount == 1)
    }
}
