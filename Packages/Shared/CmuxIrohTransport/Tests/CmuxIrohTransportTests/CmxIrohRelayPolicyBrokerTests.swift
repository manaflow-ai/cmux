import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohRelayPolicyBrokerTests {
    @Test
    func bootstrapAcceptsRevisionZeroAndNullableToken() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {
                  "token": null,
                  "expiresAt": 1782000300,
                  "ttlSeconds": 300,
                  "relays": ["https://usc1.relay.cmux.dev"],
                  "policy": "aaa.bbb.ccc",
                  "preference": {"mode":"automatic"},
                  "preferenceRevision": 0
                }
                """
            ),
        ])
        let client = try makeClient(transport: transport)

        let response = try await client.issueRelayBootstrap(
            endpointID: CmxIrohPeerIdentity(endpointID: Self.endpointID)
        )

        #expect(response.relayToken == nil)
        #expect(response.relayPolicy.preference == .automatic)
        #expect(response.relayPolicy.preferenceRevision == 0)
        let request = try #require(await transport.requests().first)
        #expect(request.url?.path == "/api/relay/token")
        #expect(request.httpMethod == "POST")
    }

    @Test
    func preferenceRoutesUseExactCanonicalWireSchema() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {
                  "preference": {
                    "mode": "managed",
                    "selectedManagedRelayIds": ["cmux-us"]
                  },
                  "preferenceRevision": 0
                }
                """
            ),
            .json(
                status: 200,
                body: """
                {
                  "preference": {
                    "mode": "custom",
                    "customRelays": [{
                      "id": "private-home",
                      "url": "https://relay.example.net:8443/",
                      "provider": "personal",
                      "region": "home",
                      "displayName": "Home relay",
                      "authMode": "device_secret"
                    }]
                  },
                  "preferenceRevision": 1
                }
                """
            ),
        ])
        let client = try makeClient(transport: transport)

        let current = try await client.relayPreference()
        let currentConfiguration = try CmxIrohAccountRelayConfiguration.managed(["cmux-us"])
        #expect(current.preference == currentConfiguration)
        #expect(current.revision == 0)

        let definition = try CmxIrohCustomRelayDefinition(
            id: "private-home",
            url: "https://relay.example.net:8443/",
            provider: "personal",
            region: "home",
            displayName: "Home relay",
            authMode: .staticToken
        )
        let updated = try await client.updateRelayPreference(
            CmxIrohRelayPreferenceUpdateRequest(
                expectedRevision: 0,
                preference: .custom([definition])
            )
        )
        let updatedConfiguration = try CmxIrohAccountRelayConfiguration.custom([definition])
        #expect(updated.preference == updatedConfiguration)
        #expect(updated.revision == 1)

        let requests = await transport.requests()
        #expect(requests.map { $0.url?.path } == [
            "/api/relay/preferences",
            "/api/relay/preferences",
        ])
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let body = try #require(requests[1].httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["expectedRevision"] as? Int == 0)
        let preference = try #require(object["preference"] as? [String: Any])
        #expect(preference["mode"] as? String == "custom")
        #expect(preference["relays"] == nil)
        #expect(preference["selectedManagedRelayIds"] as? [String] == [])
        let relays = try #require(preference["customRelays"] as? [[String: Any]])
        #expect(relays.first?["authMode"] as? String == "device_secret")
    }

    private func makeClient(
        transport: RecordingBrokerTransport
    ) throws -> CmxIrohTrustBrokerClient {
        try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                accessToken: { "access" },
                refreshToken: { "refresh" }
            ),
            transport: transport
        )
    }

    private static let endpointID =
        "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
}
