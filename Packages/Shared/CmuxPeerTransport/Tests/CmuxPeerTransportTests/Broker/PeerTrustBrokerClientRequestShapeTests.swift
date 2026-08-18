import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxPeerTransport

/// Pins every endpoint's request shape (path, method, auth headers, body
/// keys) against the fixed server contract, using fixtures carried over from
/// the previous transport's tests.
@Suite
struct PeerTrustBrokerClientRequestShapeTests {
    @Test
    func challengeUsesNativeStackHeadersAndExactJSON() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: BrokerFixtures.challengeBody),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)
        let signer = try BrokerFixtures.signer()
        let request = try signer.prepare(
            payload: BrokerFixtures.registrationPayload()
        ).challengeRequest

        let response = try await client.challenge(request)
        #expect(response.challengeID == "123e4567-e89b-42d3-a456-426614174000")

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh/challenge")
        #expect(captured.httpMethod == "POST")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(captured.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        #expect(
            captured.value(forHTTPHeaderField: "X-Cmux-App-Namespace")
                == "dev.cmux.app.internal"
        )
        let object = BrokerFixtures.bodyObject(captured)
        #expect(Set(object.keys) == [
            "deviceId", "appInstanceId", "clientNamespace", "tag",
            "endpointId", "identityGeneration", "payloadSha256",
        ])
        #expect(object["endpointId"] as? String == BrokerFixtures.endpointID)
        #expect(object["identityGeneration"] as? Int == 1)
    }

    @Test
    func combinedRegistrationRunsBothLegsAndRetainsBindingProof() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: BrokerFixtures.challengeBody),
            .json(status: 201, body: BrokerFixtures.registrationResponse),
            .json(status: 200, body: BrokerFixtures.discoveryResponse),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)
        let signer = try BrokerFixtures.signer()
        let prepared = try signer.prepare(payload: BrokerFixtures.registrationPayload())

        let response = try await client.register(prepared: prepared, signer: signer)
        #expect(response.binding.tag == "stable")
        #expect(await client.bindingAuthorizationID() == BrokerFixtures.bindingID)
        _ = try await client.discover()

        let requests = await transport.requests()
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/devices/iroh/challenge",
            "/api/devices/iroh/register",
            "/api/devices/iroh",
        ])
        let register = requests[1]
        let registerBody = BrokerFixtures.bodyObject(register)
        #expect(Set(registerBody.keys) == ["challengeId", "nonce", "payload", "signature"])
        #expect((registerBody["signature"] as? String)?.count == 86)
        // Challenge and register legs never carry the binding proof; the
        // post-registration request carries all three signed headers.
        #expect(
            requests.dropLast().allSatisfy {
                $0.value(forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature") == nil
            }
        )
        let discovery = requests[2]
        #expect(
            discovery.value(forHTTPHeaderField: "X-Cmux-Iroh-Binding-ID")
                == BrokerFixtures.bindingID
        )
        #expect(
            Int64(discovery.value(forHTTPHeaderField: "X-Cmux-Iroh-Request-Time") ?? "")
                != nil
        )
        #expect(
            discovery.value(forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature")?.count
                == 86
        )
        guard case let .issued(relay) = response.relay else {
            Issue.record("Expected an issued relay credential")
            return
        }
        #expect(relay.relayFleet == BrokerFixtures.relayURLs)
        #expect(relay.credentials.allSatisfy { $0.token == "abc234" })
    }

    @Test
    func scopedRegistrationSendsScopeAndAcceptsOnlyItsEchoedProjection() async throws {
        let scope = try BrokerFixtures.iosDiscoveryScope()
        var responseObject = BrokerFixtures.jsonObject(BrokerFixtures.registrationResponse)
        responseObject["revision"] = 7
        var discoveryObject = BrokerFixtures.jsonObject(BrokerFixtures.discoveryResponse)
        discoveryObject["revision"] = 7
        responseObject["discovery"] = discoveryObject
        responseObject["discovery_scope"] = BrokerFixtures.jsonObject(
            String(data: try JSONEncoder().encode(scope), encoding: .utf8)!
        )
        responseObject["discovery_scope_complete"] = true
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: BrokerFixtures.jsonString(responseObject)),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            discoveryScope: scope
        )

        let response = try await client.register(
            PeerBrokerRegisterRequest(
                challengeID: "123e4567-e89b-42d3-a456-426614174000",
                nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                payload: "e30",
                signature: String(repeating: "A", count: 86)
            )
        )

        #expect(response.discoveryScope == scope)
        #expect(response.embeddedDiscoveryComplete)
        let captured = try #require(await transport.requests().first)
        let body = BrokerFixtures.bodyObject(captured)
        #expect(body["discoveryScope"] != nil)
    }

    @Test
    func scopedRegistrationRejectsAResponseWithoutTheCompleteProjection() async throws {
        let scope = try BrokerFixtures.iosDiscoveryScope()
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: BrokerFixtures.registrationResponse),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            discoveryScope: scope
        )

        await #expect(throws: PeerBrokerError.protocolError) {
            _ = try await client.register(
                PeerBrokerRegisterRequest(
                    challengeID: "123e4567-e89b-42d3-a456-426614174000",
                    nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                    payload: "e30",
                    signature: String(repeating: "A", count: 86)
                )
            )
        }
    }

    @Test
    func discoveryTraversesBoundedPagesAndPreservesOneRevision() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try BrokerFixtures.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1",
                    revision: 41
                )
            ),
            .json(
                status: 200,
                body: try BrokerFixtures.discoveryResponse(
                    bindingRange: 129 ..< 257,
                    nextCursor: "cursor-2",
                    revision: 41
                )
            ),
            .json(
                status: 200,
                body: try BrokerFixtures.discoveryResponse(
                    bindingRange: 257 ..< 301,
                    nextCursor: nil,
                    revision: 41
                )
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.bindings.count == 300)
        #expect(Set(discovery.bindings.map(\.bindingID)).count == 300)
        #expect(discovery.revision == 41)
        let requests = await transport.requests()
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.map { $0.url?.query } == [
            "page_size=128",
            "page_size=128&cursor=cursor-1",
            "page_size=128&cursor=cursor-2",
        ])
    }

    @Test
    func discoveryRestartsAfterAStaleCursorRejection() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try BrokerFixtures.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1",
                    revision: 41
                )
            ),
            .json(status: 409, body: #"{"error":"discovery_cursor_stale"}"#),
            .json(
                status: 200,
                body: try BrokerFixtures.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-2",
                    revision: 42
                )
            ),
            .json(
                status: 200,
                body: try BrokerFixtures.discoveryResponse(
                    bindingRange: 129 ..< 130,
                    nextCursor: nil,
                    revision: 42
                )
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.revision == 42)
        #expect(discovery.bindings.count == 129)
        #expect(await transport.requests().count == 4)
    }

    @Test
    func discoveryBoundsRepeatedSnapshotRestarts() async throws {
        let responses = try (0 ..< 3).flatMap { attempt -> [RecordingBrokerTransport.Response] in
            [
                .json(
                    status: 200,
                    body: try BrokerFixtures.discoveryResponse(
                        bindingRange: 1 ..< 129,
                        nextCursor: "cursor-\(attempt)",
                        revision: 41 + attempt
                    )
                ),
                .json(
                    status: 200,
                    body: try BrokerFixtures.discoveryResponse(
                        bindingRange: 129 ..< 130,
                        nextCursor: nil,
                        revision: 42 + attempt
                    )
                ),
            ]
        }
        let transport = RecordingBrokerTransport(responses: responses)
        let client = try BrokerFixtures.makeClient(transport: transport)

        await #expect(throws: PeerBrokerError.protocolError) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().count == 6)
    }
}
