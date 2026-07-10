import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
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

    @Test
    func missingAuthFailsBeforeAnyNetworkRequest() async throws {
        let transport = RecordingBrokerTransport(responses: [])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: try #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                accessToken: { nil },
                refreshToken: { "refresh" }
            ),
            transport: transport
        )
        await #expect(throws: CmxIrohTrustBrokerClientError.missingAuthentication) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func cleartextRemoteOriginIsRejected() throws {
        #expect(throws: CmxIrohTrustBrokerClientError.invalidBaseURL) {
            _ = try CmxIrohTrustBrokerClient(
                baseURL: #require(URL(string: "http://cmux.example")),
                tokenSource: Self.tokenSource,
                transport: RecordingBrokerTransport(responses: [])
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
    private static let relayURLs = [
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
    ]
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

private actor RecordingBrokerTransport: CmxIrohHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: Data

        static func json(status: Int, body: String) -> Self {
            Self(status: status, body: Data(body.utf8))
        }
    }

    private var pending: [Response]
    private var captured: [URLRequest] = []

    init(responses: [Response]) {
        pending = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        let response = pending.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response.body, http)
    }

    func requests() -> [URLRequest] { captured }
}
