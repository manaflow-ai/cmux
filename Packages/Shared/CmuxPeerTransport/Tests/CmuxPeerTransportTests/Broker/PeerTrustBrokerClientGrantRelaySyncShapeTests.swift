import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxPeerTransport

/// Pins the grant, relay-token, connectivity-sync, and revocation request
/// shapes (path, method, body keys) against the fixed server contract.
@Suite
struct PeerTrustBrokerClientGrantRelaySyncShapeTests {
    @Test
    func pairGrantUsesExactPathAndBodyKeys() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: #"{"grant":"token","expires_at":"2026-07-17T00:00:00.000Z"}"#
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        let response = try await client.issuePairGrant(
            initiatorBindingID: "123e4567-e89b-42d3-a456-426614174001",
            acceptorBindingID: "123e4567-e89b-42d3-a456-426614174002"
        )

        #expect(response.grant == "token")
        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh/pair-grants")
        #expect(captured.httpMethod == "POST")
        let object = BrokerFixtures.bodyObject(captured)
        #expect(Set(object.keys) == ["initiatorBindingId", "acceptorBindingId"])
        #expect(
            object["initiatorBindingId"] as? String
                == "123e4567-e89b-42d3-a456-426614174001"
        )
    }

    @Test
    func endpointAttestationUsesExactPathAndBodyKeys() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: """
                {"attestation_version":1,"attestation":"proof","expires_at":"2026-07-11T00:00:00.000Z","grant_verification_keys":{"version":1,"current_kid":"current","keys":[]}}
                """
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        let response = try await client.issueEndpointAttestation(
            bindingID: BrokerFixtures.bindingID
        )

        #expect(response.attestation == "proof")
        #expect(response.attestationVersion == 1)
        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh/endpoint-attestations")
        #expect(captured.httpMethod == "POST")
        let object = BrokerFixtures.bodyObject(captured)
        #expect(Set(object.keys) == ["bindingId"])
        #expect(object["bindingId"] as? String == BrokerFixtures.bindingID)
    }

    @Test
    func relayTokenBindsCanonicalHexEndpointAndNormalizesFleetOrigins() async throws {
        let jwt = BrokerFixtures.makeRelayJWT(endpointID: BrokerFixtures.endpointID)
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"token":"\(jwt)","expiresAt":1782000300,"ttlSeconds":300,"relays":["https://usc1.relay.cmux.dev","https://euw4.relay.cmux.dev/"]}
                """
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: BrokerFixtures.endpointID)

        let response = try await client.relayToken(endpointID: endpointID)

        #expect(response.relayFleet == [
            "https://usc1.relay.cmux.dev/",
            "https://euw4.relay.cmux.dev/",
        ])
        #expect(response.credentials.allSatisfy { $0.token == jwt })
        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/relay/token")
        #expect(captured.httpMethod == "POST")
        let object = BrokerFixtures.bodyObject(captured)
        #expect(Set(object.keys) == ["endpointId"])
        #expect(object["endpointId"] as? String == BrokerFixtures.endpointID)
    }

    @Test
    func relayTokenRejectsCredentialAssociationForAnotherEndpoint() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"endpointId":"\(String(repeating: "f", count: 64))","relayCredentials":[{"relayUrl":"https://usc1.relay.cmux.dev/","token":"abc234","expiresAt":1782000300,"refreshAfter":1782000240,"ttlSeconds":300}]}
                """
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: BrokerFixtures.endpointID)

        await #expect(throws: PeerBrokerError.protocolError) {
            _ = try await client.relayToken(endpointID: endpointID)
        }
    }

    @Test
    func relayTokenPreservesDistinctServerDrivenCredentials() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"endpointId":"\(BrokerFixtures.endpointID)","relayCredentials":[
                  {"relayUrl":"https://usc1.relay.cmux.dev","token":"abc234","expiresAt":1782000300,"refreshAfter":1782000240,"ttlSeconds":300},
                  {"relayUrl":"https://relay.other.example/","token":"def567","expiresAt":1782000360,"refreshAfter":1782000240,"ttlSeconds":360}
                ]}
                """
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: BrokerFixtures.endpointID)

        let response = try await client.relayToken(endpointID: endpointID)

        #expect(response.relayFleet == [
            "https://usc1.relay.cmux.dev/",
            "https://relay.other.example/",
        ])
        #expect(response.credentials.map(\.token) == ["abc234", "def567"])
        #expect(response.credentials[0].expiresAt != response.credentials[1].expiresAt)
    }

    @Test
    func connectivitySyncSendsKnownRevisionOnV2WithoutScope() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: #"{"protocol_version":2,"revision":41,"changed":false,"reset":false}"#
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        let response = try await client.connectivitySync(knownRevision: 41)

        #expect(response.revision == 41)
        #expect(!response.changed)
        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/connectivity/v2/sync")
        #expect(captured.httpMethod == "POST")
        let object = BrokerFixtures.bodyObject(captured)
        #expect(Set(object.keys) == ["protocol_version", "known_revision"])
        #expect(object["protocol_version"] as? Int == 2)
        #expect(object["known_revision"] as? Int == 41)
    }

    @Test
    func connectivityInitialSyncEncodesExplicitNullRevision() async throws {
        var discoveryObject = BrokerFixtures.jsonObject(BrokerFixtures.discoveryResponse)
        discoveryObject["revision"] = 1
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: BrokerFixtures.jsonString([
                "protocol_version": 2,
                "revision": 1,
                "changed": true,
                "reset": false,
                "snapshot": discoveryObject,
                "snapshot_complete": true,
            ])),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        let response = try await client.connectivitySync(knownRevision: nil)

        #expect(response.snapshotComplete == true)
        let captured = try #require(await transport.requests().first)
        let object = BrokerFixtures.bodyObject(captured)
        #expect(object.keys.contains("known_revision"))
        #expect(object["known_revision"] is NSNull)
    }

    @Test
    func connectivityV3SendsAndAcceptsOnlyTheEchoedScope() async throws {
        let scope = try BrokerFixtures.iosDiscoveryScope()
        var discoveryObject = BrokerFixtures.jsonObject(BrokerFixtures.discoveryResponse)
        discoveryObject["revision"] = 2
        let scopeObject = BrokerFixtures.jsonObject(
            String(data: try JSONEncoder().encode(scope), encoding: .utf8)!
        )
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: BrokerFixtures.jsonString([
                "protocol_version": 3,
                "revision": 2,
                "changed": true,
                "reset": false,
                "discovery_scope": scopeObject,
                "snapshot": discoveryObject,
                "snapshot_scope_complete": true,
            ])),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            discoveryScope: scope
        )

        let response = try await client.connectivitySync(knownRevision: nil)

        #expect(response.protocolVersion == 3)
        #expect(response.discoveryScope == scope)
        #expect(response.snapshotIsComplete)
        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/connectivity/v3/sync")
        let object = BrokerFixtures.bodyObject(captured)
        #expect(Set(object.keys) == ["protocol_version", "known_revision", "discovery_scope"])
        #expect(object["protocol_version"] as? Int == 3)
    }

    @Test(arguments: [
        PeerBindingRevocationIntent.own,
        PeerBindingRevocationIntent.stale,
        PeerBindingRevocationIntent.forgetMac,
    ])
    func revokeBindingUsesTheDeleteRouteWithExactIntent(
        intent: PeerBindingRevocationIntent
    ) async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: #"{"revoked":true,"lan_rendezvous_rotated":true}"#),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        try await client.revokeBinding(BrokerFixtures.bindingID, intent: intent)

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh")
        #expect(captured.httpMethod == "DELETE")
        let object = BrokerFixtures.bodyObject(captured)
        #expect(object["bindingId"] as? String == BrokerFixtures.bindingID)
        switch intent {
        case .own:
            #expect(object["intent"] == nil)
        case .stale:
            #expect(object["intent"] as? String == "revoke_stale")
        case .forgetMac:
            #expect(object["intent"] as? String == "forget_mac")
        }
    }

    @Test
    func revokeBindingRejectsAnUnrotatedLANRendezvous() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: #"{"revoked":true,"lan_rendezvous_rotated":false}"#),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        await #expect(throws: PeerBrokerError.protocolError) {
            try await client.revokeBinding(BrokerFixtures.bindingID)
        }
    }
}
