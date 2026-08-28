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

    /// Persistent refresh failure must be visible host state (cmux#10873):
    /// every failed authenticated refresh round extends a published failure
    /// streak, whether the broker fetch itself failed or its response failed
    /// verification, and the streak start survives later failures.
    @Test
    func refreshFailuresPublishGrowingStreak() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let broker = ScriptedPolicyBroker(results: [
            .failure(TestRelayPolicyTransportError.offline),
            .failure(TestRelayPolicyTransportError.offline),
            .failure(TestRelayPolicyTransportError.offline),
        ])
        let service = Self.service(broker: broker)
        let firstFailureAt = fixture.now

        for attempt in 1 ... 3 {
            await #expect(throws: TestRelayPolicyTransportError.self) {
                try await service.refresh(
                    accountID: "account-a",
                    trustRoot: try fixture.firstTrustRoot,
                    now: firstFailureAt.addingTimeInterval(TimeInterval(attempt - 1))
                )
            }
            let snapshot = await service.diagnosticsSnapshot()
            #expect(snapshot.refreshFailingSince == firstFailureAt)
            #expect(snapshot.consecutiveRefreshFailures == attempt)
        }
        let snapshot = await service.diagnosticsSnapshot()
        #expect(
            snapshot.consecutiveRefreshFailures
                >= CmxIrohRelayPolicyService.persistentRefreshFailureThreshold
        )
    }

    /// A refresh whose broker response fails signature verification is a
    /// refresh failure too: the streak grows exactly as for a fetch failure.
    @Test
    func rejectedPolicyCountsTowardStreak() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let broker = ScriptedPolicyBroker(results: [
            .success(try CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1, signer: 2),
                preference: .automatic,
                preferenceRevision: 1
            )),
        ])
        let service = Self.service(broker: broker)

        await #expect(throws: (any Error).self) {
            // Signed by a key absent from the trust root.
            try await service.refresh(
                accountID: "account-a",
                trustRoot: try fixture.firstTrustRoot,
                now: fixture.now
            )
        }
        let snapshot = await service.diagnosticsSnapshot()
        #expect(snapshot.refreshFailingSince == fixture.now)
        #expect(snapshot.consecutiveRefreshFailures == 1)
    }

    /// A successful refresh clears the streak, so recovery is visible on the
    /// same surface that reported the outage.
    @Test
    func successfulRefreshClearsStreak() async throws {
        let fixture = RelayPolicyServiceTestFixture()
        let broker = ScriptedPolicyBroker(results: [
            .failure(TestRelayPolicyTransportError.offline),
            .failure(TestRelayPolicyTransportError.offline),
            .success(try CmxIrohRelayPolicyResponse(
                policy: fixture.token(sequence: 1),
                preference: .automatic,
                preferenceRevision: 1
            )),
        ])
        let service = Self.service(broker: broker)

        for _ in 1 ... 2 {
            await #expect(throws: TestRelayPolicyTransportError.self) {
                try await service.refresh(
                    accountID: "account-a",
                    trustRoot: try fixture.firstTrustRoot,
                    now: fixture.now
                )
            }
        }
        #expect(await service.diagnosticsSnapshot().consecutiveRefreshFailures == 2)

        let effective = try await service.refresh(
            accountID: "account-a",
            trustRoot: try fixture.firstTrustRoot,
            now: fixture.now
        )
        #expect(effective.endpointRelayProfile.allowedRelayURLs == Set(fixture.relayURLs))
        let snapshot = await service.diagnosticsSnapshot()
        #expect(snapshot.refreshFailingSince == nil)
        #expect(snapshot.consecutiveRefreshFailures == 0)
    }

    private static func service(
        broker: any CmxIrohRelayPolicyServing
    ) -> CmxIrohRelayPolicyService {
        CmxIrohRelayPolicyService(
            policyCache: CmxIrohRelayPolicyCache(secureStore: TestSecureCredentialStore()),
            preferenceStore: CmxIrohRelayPreferenceStore(secureStore: TestSecureCredentialStore()),
            credentialStore: CmxIrohCustomRelayCredentialStore(
                secureStore: TestSecureCredentialStore()
            ),
            broker: broker
        )
    }
}

private enum TestRelayPolicyTransportError: Error {
    case offline
}

/// Serves one scripted result per fetch, repeating the last one.
private actor ScriptedPolicyBroker: CmxIrohRelayPolicyServing {
    private var results: [Result<CmxIrohRelayPolicyResponse, any Error>]

    init(results: [Result<CmxIrohRelayPolicyResponse, any Error>]) {
        self.results = results
    }

    func fetchRelayPolicy() async throws -> CmxIrohRelayPolicyResponse {
        let result = results.count > 1 ? results.removeFirst() : results[0]
        return try result.get()
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
