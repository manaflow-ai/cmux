import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohTrustBrokerClientTests {
    @Test
    func challengeUsesNativeStackHeadersAndExactJSON() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
        ])
        let client = try makeClient(transport: transport)
        let payload = try registrationPayload()
        let signer = try registrationSigner()
        let request = try signer.prepare(payload: payload).challengeRequest

        let response = try await client.issueChallenge(request)
        #expect(response.challengeID == "123e4567-e89b-42d3-a456-426614174000")

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh/challenge")
        #expect(captured.httpMethod == "POST")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(captured.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["endpointId"] as? String == Self.endpointID)
        #expect(object["identityGeneration"] as? Int == 1)
    }

    @Test
    func issuedRegistrationBuildsTheExactManagedRelayFleet() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: Self.registrationResponse),
        ])
        let client = try makeClient(transport: transport)
        let response = try await client.register(
            CmxIrohRegisterRequest(
                challengeID: "123e4567-e89b-42d3-a456-426614174000",
                nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                payload: "e30",
                signature: String(repeating: "A", count: 86)
            )
        )
        guard case let .issued(relay) = response.relay else {
            Issue.record("Expected an issued relay credential")
            return
        }
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T00:00:00Z"))
        let configurations = try relay.relayConfigurations(now: now)
        #expect(configurations.map(\.url) == Self.relayURLs)
        #expect(configurations.allSatisfy { $0.token == "abc234" })
    }

    @Test
    func existingRegistrationAcceptsNotRequestedRelayBootstrap() async throws {
        var responseObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.registrationResponse.utf8)
            ) as? [String: Any]
        )
        responseObject["relay"] = ["status": "not_requested"]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let responseBody = try #require(String(data: responseData, encoding: .utf8))
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: responseBody),
        ])
        let client = try makeClient(transport: transport)

        let response = try await client.register(
            CmxIrohRegisterRequest(
                challengeID: "123e4567-e89b-42d3-a456-426614174000",
                nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                payload: "e30",
                signature: String(repeating: "A", count: 86)
            )
        )

        #expect(response.binding.tag == "stable")
        #expect(response.relay == .notRequested)
    }

    @Test
    func relayTokenBindsCanonicalHexEndpointAndNormalizesFleetOrigins() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"token":"\(Self.relayJWT)","expiresAt":1782000300,"ttlSeconds":300,"relays":["https://usc1.relay.cmux.dev","https://euw4.relay.cmux.dev/"]}
                """
            ),
        ])
        let client = try makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: Self.endpointID)

        let response = try await client.issueRelayToken(
            bindingID: Self.bindingID,
            endpointID: endpointID
        )

        #expect(response.relayFleet == [
            "https://usc1.relay.cmux.dev/",
            "https://euw4.relay.cmux.dev/",
        ])
        let configurations = try response.relayConfigurations(
            now: Date(timeIntervalSince1970: 1_782_000_000)
        )
        #expect(configurations.count == 2)
        #expect(configurations.allSatisfy {
            $0.token == Self.relayJWT
        })

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/relay/token")
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object.count == 1)
        #expect(object["endpointId"] as? String == Self.endpointID)
    }

    @Test
    func relayTokenPreservesDistinctCredentialsForEachServerDrivenRelay() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {
                  "endpointId":"\(Self.endpointID)",
                  "relayCredentials":[
                    {
                      "relayUrl":"https://usc1.relay.cmux.dev",
                      "token":"abc234",
                      "expiresAt":1782000300,
                      "refreshAfter":1782000240,
                      "ttlSeconds":300
                    },
                    {
                      "relayUrl":"https://relay.other.example/",
                      "token":"def567",
                      "expiresAt":1782000360,
                      "refreshAfter":1782000240,
                      "ttlSeconds":360
                    }
                  ]
                }
                """
            ),
        ])
        let client = try makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: Self.endpointID)

        let response = try await client.issueRelayToken(
            bindingID: Self.bindingID,
            endpointID: endpointID
        )

        #expect(response.relayFleet == [
            "https://usc1.relay.cmux.dev/",
            "https://relay.other.example/",
        ])
        let configurations = try response.relayConfigurations(
            now: Date(timeIntervalSince1970: 1_782_000_000)
        )
        #expect(configurations.map(\.token) == ["abc234", "def567"])
        #expect(configurations[0].expiresAt != configurations[1].expiresAt)

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/relay/token")
    }

    @Test
    func relayTokenRejectsCredentialAssociationForAnotherEndpoint() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {
                  "endpointId":"\(String(repeating: "f", count: 64))",
                  "relayCredentials":[{
                    "relayUrl":"https://usc1.relay.cmux.dev/",
                    "token":"abc234",
                    "expiresAt":1782000300,
                    "refreshAfter":1782000240,
                    "ttlSeconds":300
                  }]
                }
                """
            ),
        ])
        let client = try makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: Self.endpointID)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.issueRelayToken(
                bindingID: Self.bindingID,
                endpointID: endpointID
            )
        }
    }

    @Test
    func relayTokenRejectsCredentialCatalogAboveBound() async throws {
        let credentials = (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount + 1)
            .map { index in
                """
                {"relayUrl":"https://relay-\(index).example/","token":"abc234","expiresAt":1782000300,"refreshAfter":1782000240,"ttlSeconds":300}
                """
            }
            .joined(separator: ",")
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"endpointId":"\(Self.endpointID)","relayCredentials":[\(credentials)]}
                """
            ),
        ])
        let client = try makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: Self.endpointID)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.issueRelayToken(
                bindingID: Self.bindingID,
                endpointID: endpointID
            )
        }
    }

    @Test
    func relayTokenRejectsNonOriginFleetURL() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"token":"\(Self.relayJWT)","expiresAt":1782000300,"ttlSeconds":300,"relays":["https://relay.cmux.dev/capture"]}
                """
            ),
        ])
        let client = try makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: Self.endpointID)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.issueRelayToken(
                bindingID: Self.bindingID,
                endpointID: endpointID
            )
        }
    }

    @Test
    func relayTokenRejectsJWTBoundToAnotherEndpoint() async throws {
        let substituted = Self.makeRelayJWT(endpointID: String(repeating: "f", count: 64))
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"token":"\(substituted)","expiresAt":1782000300,"ttlSeconds":300,"relays":["https://usc1.relay.cmux.dev"]}
                """
            ),
        ])
        let client = try makeClient(transport: transport)
        let endpointID = try CmxIrohPeerIdentity(endpointID: Self.endpointID)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.issueRelayToken(
                bindingID: Self.bindingID,
                endpointID: endpointID
            )
        }
    }

    @Test
    func revokeUsesTheBrokerDeleteRoute() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: #"{"revoked":true,"lan_rendezvous_rotated":true}"#
            ),
        ])
        let client = try makeClient(transport: transport)
        let bindingID = "123e4567-e89b-42d3-a456-426614174010"

        try await client.revoke(bindingID: bindingID)

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh")
        #expect(captured.httpMethod == "DELETE")
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["bindingId"] as? String == bindingID)
    }

    @Test
    func discoveryDecodesBrokerISO8601PathHintDates() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: Self.discoveryResponse),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        let binding = try #require(discovery.bindings.first)
        let hint = try #require(binding.pathHints.first)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(hint.value == Self.relayURLs[0])
        #expect(
            hint.observedAt
                == formatter.date(from: "2026-07-10T00:00:00.000Z")
        )
        #expect(
            hint.expiresAt
                == formatter.date(from: "2026-07-10T01:00:00.000Z")
        )
    }

    @Test
    func discoveryAcceptsCombinedManagedFleetAboveLegacyLimit() async throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.discoveryResponse.utf8)
            ) as? [String: Any]
        )
        let relayFleet = (1 ... 11).map { "https://relay-\($0).example.com/" }
        object["relay_fleet"] = relayFleet
        let data = try JSONSerialization.data(withJSONObject: object)
        let body = try #require(String(data: data, encoding: .utf8))
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: body),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.relayFleet == relayFleet)
    }

    @Test
    func discoveryAcceptsDevelopmentBindingQuotaAboveProductionLimit() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: try Self.discoveryResponse(bindingCount: 33)),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.bindings.count == 33)
        #expect(Set(discovery.bindings.map(\.bindingID)).count == 33)
    }

    @Test
    func discoveryRejectsBindingsAboveDevelopmentQuota() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: try Self.discoveryResponse(bindingCount: 257)),
        ])
        let client = try makeClient(transport: transport)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.discover()
        }
    }

    @Test
    func brokerErrorMapsOnlyStatusAndCoarseCode() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 403, body: #"{"error":"target_not_pairable","secret":"do-not-copy"}"#),
        ])
        let client = try makeClient(transport: transport)
        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 403,
            code: "target_not_pairable"
        )) {
            _ = try await client.issuePairGrant(
                initiatorBindingID: "123e4567-e89b-42d3-a456-426614174001",
                acceptorBindingID: "123e4567-e89b-42d3-a456-426614174002"
            )
        }
    }

    private func makeClient(
        transport: RecordingBrokerTransport
    ) throws -> CmxIrohTrustBrokerClient {
        try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: Self.tokenSource,
            transport: transport
        )
    }

    private func registrationSigner() throws -> CmxIrohRegistrationSigner {
        let secret = try CmxIrohSecretKey(bytes: Data((0 ..< 32).map(UInt8.init)))
        let material = try CmxIrohIdentityMaterial(
            secretKey: secret,
            generation: 1
        )
        return try CmxIrohRegistrationSigner(identity: material, endpointID: Self.endpointID)
    }

    private func registrationPayload() throws -> CmxIrohRegistrationPayload {
        try CmxIrohRegistrationPayload(
            deviceID: "123e4567-e89b-42d3-a456-426614174001",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "stable",
            platform: .ios,
            endpointID: Self.endpointID,
            identityGeneration: 1,
            pairingEnabled: false,
            capabilities: ["control"],
            pathHints: [],
            now: Date(timeIntervalSince1970: 1_782_000_000)
        )
    }

    private static let tokenSource = CmxIrohBrokerTokenSource(
        accessToken: { "access" },
        refreshToken: { "refresh" }
    )
    private static let endpointID =
        "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
    private static let bindingID = "123e4567-e89b-42d3-a456-426614174010"
    private static let relayJWT = makeRelayJWT(endpointID: endpointID)
    private static let relayURLs = [
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
    ]

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeRelayJWT(endpointID: String) -> String {
        [
            base64URL(#"{"alg":"EdDSA","typ":"JWT"}"#),
            base64URL(
                #"{"iss":"cmux","aud":"cmux-relay","exp":1782000300,"endpoint_id":"\#(endpointID)"}"#
            ),
            "signature",
        ].joined(separator: ".")
    }

    private static func discoveryResponse(bindingCount: Int) throws -> String {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(discoveryResponse.utf8)
            ) as? [String: Any]
        )
        let template = try #require((object["bindings"] as? [[String: Any]])?.first)
        object["bindings"] = (1 ... bindingCount).map { index in
            var binding = template
            binding["binding_id"] = String(
                format: "123e4567-e89b-42d3-a456-%012d",
                index
            )
            binding["app_instance_id"] = String(
                format: "223e4567-e89b-42d3-a456-%012d",
                index
            )
            binding["endpoint_id"] = String(format: "%064llx", UInt64(index))
            return binding
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static let registrationResponse = """
    {
      "binding": {
        "binding_id": "123e4567-e89b-42d3-a456-426614174010",
        "device_id": "123e4567-e89b-42d3-a456-426614174001",
        "app_instance_id": "123e4567-e89b-42d3-a456-426614174002",
        "tag": "stable",
        "platform": "ios",
        "display_name": null,
        "endpoint_id": "\(endpointID)",
        "identity_generation": 1,
        "pairing_enabled": false,
        "capabilities": ["control"],
        "path_hints": [],
        "last_seen_at": "2026-07-10T00:00:00.000Z"
      },
      "relay": {
        "status": "issued",
        "token": "abc234",
        "expires_at": "2026-07-11T00:00:00.000Z",
        "refresh_after": "2026-07-10T12:00:00.000Z",
        "relay_fleet": [
          "https://euc1-1.relay.lawrence.cmux.iroh.link/",
          "https://use1-1.relay.lawrence.cmux.iroh.link/"
        ]
      }
    }
    """
    private static let discoveryResponse = """
    {
      "route_contract_version": 1,
      "bindings": [{
        "binding_id": "123e4567-e89b-42d3-a456-426614174010",
        "device_id": "123e4567-e89b-42d3-a456-426614174001",
        "app_instance_id": "123e4567-e89b-42d3-a456-426614174002",
        "tag": "stable",
        "platform": "mac",
        "display_name": "Mac",
        "endpoint_id": "\(endpointID)",
        "identity_generation": 1,
        "pairing_enabled": true,
        "capabilities": ["control"],
        "path_hints": [{
          "kind": "relay_url",
          "value": "\(relayURLs[0])",
          "source": "native",
          "privacy_scope": "public_internet",
          "observed_at": "2026-07-10T00:00:00.000Z",
          "expires_at": "2026-07-10T01:00:00.000Z"
        }],
        "last_seen_at": "2026-07-10T00:00:00.000Z"
      }],
      "relay_fleet": ["\(relayURLs[0])"],
      "lan_rendezvous": {
        "generation": 1,
        "key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      },
      "grant_verification_keys": {
        "version": 1,
        "current_kid": "current",
        "keys": []
      }
    }
    """
}
