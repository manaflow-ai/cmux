import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohBackpressuredHostBrokerTests {
    @Test
    func endpointAttestationFloorIsIsolatedAndRelayCredentialIsShared() async throws {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let accountID = "account-a"
        let gate = CmxIrohBrokerBackpressureGate(now: { now })
        let probe = BackpressuredHostBrokerProbe()
        let host = CmxIrohBackpressuredHostBroker(
            broker: probe,
            gate: gate,
            accountID: accountID
        )
        let relayPolicy = CmxIrohBackpressuredRelayPolicyBroker(
            broker: probe,
            gate: gate,
            accountID: accountID
        )
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let attestationLimit = CmxIrohTrustBrokerClientError.rateLimited(
            code: "attestation_rate_limited",
            retryAfterSeconds: 600
        )
        let relayLimit = CmxIrohTrustBrokerClientError.rateLimited(
            code: "relay_rate_limited",
            retryAfterSeconds: 600
        )

        await #expect(throws: attestationLimit) {
            _ = try await host.issueEndpointAttestation(bindingID: "binding-a")
        }
        #expect(await probe.calls() == BackpressuredHostBrokerProbeCalls(
            endpointAttestation: 1,
            relayToken: 0,
            relayBootstrap: 0
        ))
        #expect(await gate.remainingSeconds(
            accountID: accountID,
            operation: .endpointAttestation
        ) == 600)
        #expect(await gate.remainingSeconds(
            accountID: accountID,
            operation: .relayCredential
        ) == nil)

        await #expect(throws: relayLimit) {
            _ = try await host.issueRelayToken(
                bindingID: "binding-a",
                endpointID: endpointID
            )
        }
        #expect(await probe.calls() == BackpressuredHostBrokerProbeCalls(
            endpointAttestation: 1,
            relayToken: 1,
            relayBootstrap: 0
        ))
        #expect(await gate.remainingSeconds(
            accountID: accountID,
            operation: .endpointAttestation
        ) == 600)
        #expect(await gate.remainingSeconds(
            accountID: accountID,
            operation: .relayCredential
        ) == 600)

        await #expect(throws: relayLimit) {
            _ = try await relayPolicy.issueRelayBootstrap(endpointID: endpointID)
        }
        #expect(await probe.calls() == BackpressuredHostBrokerProbeCalls(
            endpointAttestation: 1,
            relayToken: 1,
            relayBootstrap: 0
        ))
    }
}

private struct BackpressuredHostBrokerProbeCalls: Equatable, Sendable {
    let endpointAttestation: Int
    let relayToken: Int
    let relayBootstrap: Int
}

private enum BackpressuredHostBrokerProbeError: Error, Sendable {
    case unexpectedCall
}

private actor BackpressuredHostBrokerProbe:
    CmxIrohHostBrokerServing,
    CmxIrohRelayPolicyServing
{
    private var endpointAttestationCalls = 0
    private var relayTokenCalls = 0
    private var relayBootstrapCalls = 0

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) async throws -> CmxIrohRegistrationResponse {
        throw BackpressuredHostBrokerProbeError.unexpectedCall
    }

    func discover() async throws -> CmxIrohDiscoveryResponse {
        throw BackpressuredHostBrokerProbeError.unexpectedCall
    }

    func issueEndpointAttestation(
        bindingID _: String
    ) async throws -> CmxIrohEndpointAttestationResponse {
        endpointAttestationCalls += 1
        throw CmxIrohTrustBrokerClientError.rateLimited(
            code: "attestation_rate_limited",
            retryAfterSeconds: 600
        )
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayTokenResponse {
        relayTokenCalls += 1
        throw CmxIrohTrustBrokerClientError.rateLimited(
            code: "relay_rate_limited",
            retryAfterSeconds: 600
        )
    }

    func revoke(bindingID _: String) async throws {
        throw BackpressuredHostBrokerProbeError.unexpectedCall
    }

    func issueRelayBootstrap(
        endpointID _: CmxIrohPeerIdentity
    ) async throws -> CmxIrohRelayBootstrapResponse {
        relayBootstrapCalls += 1
        throw BackpressuredHostBrokerProbeError.unexpectedCall
    }

    func relayPreference() async throws -> CmxIrohRelayPreferenceResponse {
        throw BackpressuredHostBrokerProbeError.unexpectedCall
    }

    func updateRelayPreference(
        _: CmxIrohRelayPreferenceUpdateRequest
    ) async throws -> CmxIrohRelayPreferenceResponse {
        throw BackpressuredHostBrokerProbeError.unexpectedCall
    }

    func calls() -> BackpressuredHostBrokerProbeCalls {
        BackpressuredHostBrokerProbeCalls(
            endpointAttestation: endpointAttestationCalls,
            relayToken: relayTokenCalls,
            relayBootstrap: relayBootstrapCalls
        )
    }
}
