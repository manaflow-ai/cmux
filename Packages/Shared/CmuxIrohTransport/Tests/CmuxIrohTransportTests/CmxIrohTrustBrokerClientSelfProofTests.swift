import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

/// Single-round registration: the client proves live key possession with a
/// self-contained proof (client nonce + issuedAt in the signed transcript),
/// collapsing the challenge+register pair into ONE broker round. Deployed
/// two-step brokers keep working through an explicit fallback.
@Suite
struct CmxIrohTrustBrokerClientSelfProofTests {
    @Test
    func registrationCompletesInOneBrokerRound() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: Self.registrationResponse),
        ])
        let client = try makeClient(transport: transport)
        let signer = try registrationSigner()
        let prepared = try signer.prepare(payload: registrationPayload())

        let response = try await client.register(prepared: prepared, signer: signer)

        #expect(response.binding.tag == "stable")
        let requests = await transport.requests()
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/devices/iroh/register",
        ])
        let bodyData = try #require(requests.first?.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(body["challengeId"] == nil)
        let issuedAt = try #require(body["issuedAt"] as? Int64)
        let nonce = try #require(body["nonce"] as? String)
        let signature = try #require(body["signature"] as? String)
        // The proof must verify over the exact v2 wire transcript.
        let transcript = Data(
            "cmux/iroh/device-registration/v2\n\(issuedAt)\n\(nonce)\n\(prepared.payloadSHA256)"
                .utf8
        )
        let secret = Data((0 ..< 32).map(UInt8.init))
        let publicKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: secret
        ).publicKey
        #expect(publicKey.isValidSignature(
            try Self.decodeBase64URL(signature),
            for: transcript
        ))
        // The nonce is 32 client-generated random bytes.
        #expect(try Self.decodeBase64URL(nonce).count == 32)
        // Freshness comes from the signed timestamp.
        #expect(abs(Date().timeIntervalSince1970 - TimeInterval(issuedAt)) < 60)
    }

    @Test
    func oldServerWithoutSelfProofFallsBackToTwoStepRegistration() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 400, body: #"{"error":"invalid_challenge_id"}"#),
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
            .json(status: 201, body: Self.registrationResponse),
        ])
        let client = try makeClient(transport: transport)
        let signer = try registrationSigner()
        let prepared = try signer.prepare(payload: registrationPayload())

        let response = try await client.register(prepared: prepared, signer: signer)

        #expect(response.binding.tag == "stable")
        #expect(await transport.requests().compactMap { $0.url?.path } == [
            "/api/devices/iroh/register",
            "/api/devices/iroh/challenge",
            "/api/devices/iroh/register",
        ])
    }

    @Test
    func skewedClientClockFallsBackToTwoStepRegistration() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 403, body: #"{"error":"self_proof_expired"}"#),
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
            .json(status: 201, body: Self.registrationResponse),
        ])
        let client = try makeClient(transport: transport)
        let signer = try registrationSigner()
        let prepared = try signer.prepare(payload: registrationPayload())

        let response = try await client.register(prepared: prepared, signer: signer)

        #expect(response.binding.tag == "stable")
        #expect(await transport.requests().compactMap { $0.url?.path } == [
            "/api/devices/iroh/register",
            "/api/devices/iroh/challenge",
            "/api/devices/iroh/register",
        ])
    }

    @Test
    func authoritativeRegistrationRejectionDoesNotRetryAsTwoStep() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 403, body: #"{"error":"client_namespace_mismatch"}"#),
        ])
        let client = try makeClient(transport: transport)
        let signer = try registrationSigner()
        let prepared = try signer.prepare(payload: registrationPayload())

        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 403,
            code: "client_namespace_mismatch"
        )) {
            try await client.register(prepared: prepared, signer: signer)
        }
        #expect(await transport.requests().count == 1)
    }

    // MARK: - Support

    private func makeClient(
        transport: RecordingBrokerTransport,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil
    ) throws -> CmxIrohTrustBrokerClient {
        try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: Self.tokenSource,
            clientNamespace: "dev.cmux.app.internal",
            discoveryScope: discoveryScope,
            transport: transport
        )
    }

    private func registrationSigner() throws -> CmxIrohRegistrationSigner {
        let secret = try CmxIrohSecretKey(bytes: Data((0 ..< 32).map(UInt8.init)))
        return try CmxIrohRegistrationSigner(
            identity: CmxIrohIdentityMaterial(secretKey: secret, generation: 1),
            endpointID: Self.endpointID
        )
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

    private static func decodeBase64URL(_ value: String) throws -> Data {
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        return try #require(Data(base64Encoded: base64))
    }

    private static let tokenSource = CmxIrohBrokerTokenSource(
        credentialPair: {
            CmxIrohBrokerCredentials(accessToken: "access", refreshToken: "refresh")
        }
    )
    private static let endpointID =
        "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"

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
        "status": "unavailable"
      }
    }
    """
}
