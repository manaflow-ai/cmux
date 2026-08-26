import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohTrustBrokerClientTests {
    @Test
    func discoveryScopeNormalizesOnlyPeerTags() throws {
        let scope = try CmxConnectivityDiscoveryScope(
            deviceID: "123e4567-e89b-42d3-a456-426614174001",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "LocalFeatureA",
            platform: .ios,
            peerPlatform: .mac,
            peerTags: ["FeatureA"]
        )

        #expect(scope.localBinding.tag == "LocalFeatureA")
        #expect(scope.peerBindings.tags == ["featurea"])
    }

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

    /// The DEBUG-only deployment-protection bypass rides every broker
    /// request so a tagged test build can reach a protected preview.
    @Test
    func brokerRequestsCarryDebugProtectionBypassHeaderWhenActive() async throws {
        UserDefaults.standard.set(
            "test-bypass-token",
            forKey: CmxIrohDebugBrokerBypassHeader.key
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: CmxIrohDebugBrokerBypassHeader.key
            )
        }
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
        ])
        let client = try makeClient(transport: transport)
        let payload = try registrationPayload()
        let signer = try registrationSigner()
        _ = try await client.issueChallenge(
            try signer.prepare(payload: payload).challengeRequest
        )

        let captured = try #require(await transport.requests().first)
        #expect(
            captured.value(forHTTPHeaderField: "x-vercel-protection-bypass")
                == "test-bypass-token"
        )
    }

    @Test
    func brokerRequestsOmitProtectionBypassHeaderWhenInactive() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
        ])
        let client = try makeClient(transport: transport)
        let payload = try registrationPayload()
        let signer = try registrationSigner()
        _ = try await client.issueChallenge(
            try signer.prepare(payload: payload).challengeRequest
        )

        let captured = try #require(await transport.requests().first)
        #expect(
            captured.value(forHTTPHeaderField: "x-vercel-protection-bypass") == nil
        )
    }

    /// Only bounded single-line tokens are usable as a bypass header value.
    @Test(arguments: [
        nil,
        "",
        "   ",
        "two words",
        "line\nbreak",
        String(repeating: "a", count: 129),
    ] as [String?])
    func bypassRejectsUnusableValues(_ raw: String?) {
        #expect(CmxIrohDebugBrokerBypassHeader.value(rawValue: raw) == nil)
    }

    @Test
    func bypassTrimsAndAcceptsBoundedToken() {
        #expect(
            CmxIrohDebugBrokerBypassHeader.value(rawValue: " V4wToken123 ")
                == "V4wToken123"
        )
    }

    @Test
    func combinedRegistrationUsesOneGateForBothHTTPLegs() async throws {
        let transport = RecordingBrokerTransport(responses: [
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
        #expect(response.discoveryComplete == nil)
        #expect(await transport.requests().compactMap { $0.url?.path } == [
            "/api/devices/iroh/challenge",
            "/api/devices/iroh/register",
        ])
    }

    @Test
    func postRegistrationRequestsCarryExactBindingProof() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
            .json(status: 201, body: Self.registrationResponse),
            .json(status: 200, body: Self.discoveryResponse),
        ])
        let client = try makeClient(transport: transport)
        let signer = try registrationSigner()
        let prepared = try signer.prepare(payload: registrationPayload())

        _ = try await client.register(prepared: prepared, signer: signer)
        _ = try await client.discover()

        let requests = await transport.requests()
        let discovery = try #require(requests.last)
        #expect(
            discovery.value(forHTTPHeaderField: "X-Cmux-Iroh-Binding-ID")
                == "123e4567-e89b-42d3-a456-426614174010"
        )
        #expect(
            Int64(
                discovery.value(
                    forHTTPHeaderField: "X-Cmux-Iroh-Request-Time"
                ) ?? ""
            ) != nil
        )
        #expect(
            discovery.value(
                forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature"
            )?.count == 86
        )
        #expect(
            requests.dropLast().allSatisfy {
                $0.value(
                    forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature"
                ) == nil
            }
        )
    }

    @Test
    func freshManagementClientUsesRetainedBindingProof() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: Self.discoveryResponse),
        ])
        let authorization = try CmxIrohBindingRequestAuthorization(
            bindingID: Self.bindingID,
            clientNamespace: "dev.cmux.app.internal",
            identity: identityMaterial(),
            endpointID: CmxIrohPeerIdentity(endpointID: Self.endpointID)
        )
        let client = try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: Self.tokenSource,
            clientNamespace: "dev.cmux.app.internal",
            bindingAuthorization: authorization,
            transport: transport
        )

        _ = try await client.discover()

        let request = try #require(await transport.requests().first)
        #expect(
            request.value(forHTTPHeaderField: "X-Cmux-App-Namespace")
                == "dev.cmux.app.internal"
        )
        #expect(
            request.value(forHTTPHeaderField: "X-Cmux-Iroh-Binding-ID")
                == Self.bindingID
        )
        #expect(
            request.value(forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature")?
                .count == 86
        )
    }

    @Test
    func registrationDecodesEmbeddedAuthoritativeDiscovery() async throws {
        var responseObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.registrationResponse.utf8)
            ) as? [String: Any]
        )
        responseObject["revision"] = 7
        responseObject["discovery"] = try Self.discoveryObject(revision: 7)
        responseObject["discovery_complete"] = true
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: try Self.jsonString(responseObject)),
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

        #expect(response.revision == 7)
        #expect(response.discovery?.revision == 7)
        #expect(response.discovery?.bindings.count == 1)
        #expect(response.discoveryComplete == true)
    }

    @Test
    func scopedRegistrationFallsBackWithoutRegeneratingSignedPayload() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 201,
                body: #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#
            ),
            .json(status: 400, body: #"{"error":"unknown_field"}"#),
            .json(status: 201, body: Self.registrationResponse),
        ])
        let client = try makeClient(
            transport: transport,
            discoveryScope: iosDiscoveryScope()
        )
        let signer = try registrationSigner()
        let prepared = try signer.prepare(payload: registrationPayload())

        _ = try await client.register(prepared: prepared, signer: signer)

        let requests = await transport.requests()
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/devices/iroh/challenge",
            "/api/devices/iroh/register",
            "/api/devices/iroh/register",
        ])
        let scopedBody = try #require(requests[1].httpBody)
        let fallbackBody = try #require(requests[2].httpBody)
        var scopedObject = try #require(
            JSONSerialization.jsonObject(with: scopedBody) as? [String: Any]
        )
        let fallbackObject = try #require(
            JSONSerialization.jsonObject(with: fallbackBody) as? [String: Any]
        )
        #expect(scopedObject.removeValue(forKey: "discoveryScope") != nil)
        #expect(scopedObject as NSDictionary == fallbackObject as NSDictionary)
    }

    @Test
    func scopedRegistrationAcceptsOnlyItsEchoedCompleteProjection() async throws {
        let scope = try iosDiscoveryScope()
        var responseObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.registrationResponse.utf8)
            ) as? [String: Any]
        )
        responseObject["revision"] = 7
        responseObject["discovery"] = try Self.discoveryObject(revision: 7)
        responseObject["discovery_complete"] = false
        responseObject["discovery_scope"] = try scopeObject(scope)
        responseObject["discovery_scope_complete"] = true
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: try Self.jsonString(responseObject)),
        ])
        let client = try makeClient(
            transport: transport,
            discoveryScope: scope
        )

        let response = try await client.register(
            CmxIrohRegisterRequest(
                challengeID: "123e4567-e89b-42d3-a456-426614174000",
                nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                payload: "e30",
                signature: String(repeating: "A", count: 86)
            )
        )

        #expect(response.discoveryScope == scope)
        #expect(response.discoveryScopeComplete == true)
        #expect(response.embeddedDiscoveryComplete)
    }

    @Test
    func scopedRegistrationCompletenessRequiresAnEchoedScope() async throws {
        var responseObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.registrationResponse.utf8)
            ) as? [String: Any]
        )
        responseObject["revision"] = 7
        responseObject["discovery"] = try Self.discoveryObject(revision: 7)
        responseObject["discovery_complete"] = false
        responseObject["discovery_scope_complete"] = true
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 201, body: try Self.jsonString(responseObject)),
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

        #expect(response.discoveryScope == nil)
        #expect(response.discoveryScopeComplete == true)
        #expect(!response.embeddedDiscoveryComplete)
    }

    /// A legacy "issued" relay status decodes without retaining any token:
    /// clients hold no relay credentials, so the payload is dropped on the
    /// floor and the status collapses to the credential-free case.
    @Test
    func issuedRegistrationRelayStatusDecodesWithoutRetainingTokens() async throws {
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
        #expect(response.relay == .unavailable)
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
        #expect(object["intent"] == nil)
    }

    @Test
    func forgetMacUsesExplicitAccountManagementIntent() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: #"{"revoked":true,"lan_rendezvous_rotated":true}"#
            ),
        ])
        let client = try makeClient(transport: transport)

        try await client.forgetMac(bindingID: Self.bindingID)

        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/devices/iroh")
        #expect(captured.httpMethod == "DELETE")
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["bindingId"] as? String == Self.bindingID)
        #expect(object["intent"] as? String == "forget_mac")
    }

    @Test
    func revokeStaleUsesExplicitStaleCleanupIntent() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: #"{"revoked":true,"lan_rendezvous_rotated":true}"#
            ),
        ])
        let client = try makeClient(transport: transport)

        try await client.revokeStale(bindingID: Self.bindingID)

        let captured = try #require(await transport.requests().first)
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["bindingId"] as? String == Self.bindingID)
        #expect(object["intent"] as? String == "revoke_stale")
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
    func discoveryTraversesMoreThanLegacyBindingLimitAcrossBoundedPages() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1"
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 129 ..< 257,
                    nextCursor: "cursor-2"
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 257 ..< 301,
                    nextCursor: nil
                )
            ),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.bindings.count == 300)
        #expect(Set(discovery.bindings.map(\.bindingID)).count == 300)
        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests.map { $0.url?.query } == [
            "page_size=128",
            "page_size=128&cursor=cursor-1",
            "page_size=128&cursor=cursor-2",
        ])
    }

    @Test
    func paginatedDiscoveryPreservesOneAccountRevision() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1",
                    revision: 41
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 129 ..< 130,
                    nextCursor: nil,
                    revision: 41
                )
            ),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.revision == 41)
    }

    @Test
    func paginatedDiscoveryRestartsAfterAnAccountRevisionChange() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1",
                    revision: 41
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 129 ..< 130,
                    nextCursor: nil,
                    revision: 42
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-2",
                    revision: 42
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 129 ..< 130,
                    nextCursor: nil,
                    revision: 42
                )
            ),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.revision == 42)
        #expect(discovery.bindings.count == 129)
        #expect(await transport.requests().map { $0.url?.query } == [
            "page_size=128",
            "page_size=128&cursor=cursor-1",
            "page_size=128",
            "page_size=128&cursor=cursor-2",
        ])
    }

    @Test
    func paginatedDiscoveryRestartsAfterAStaleCursorRejection() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1",
                    revision: 41
                )
            ),
            .json(status: 409, body: #"{"error":"discovery_cursor_stale"}"#),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-2",
                    revision: 42
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 129 ..< 130,
                    nextCursor: nil,
                    revision: 42
                )
            ),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.revision == 42)
        #expect(discovery.bindings.count == 129)
        #expect(await transport.requests().map { $0.url?.query } == [
            "page_size=128",
            "page_size=128&cursor=cursor-1",
            "page_size=128",
            "page_size=128&cursor=cursor-2",
        ])
    }

    @Test
    func paginatedDiscoveryBoundsRepeatedSnapshotRestarts() async throws {
        let responses = try (0 ..< 3).flatMap { attempt in
            let revision = 41 + attempt
            return [
                RecordingBrokerTransport.Response.json(
                    status: 200,
                    body: try Self.discoveryResponse(
                        bindingRange: 1 ..< 129,
                        nextCursor: "cursor-\(attempt)",
                        revision: revision
                    )
                ),
                RecordingBrokerTransport.Response.json(
                    status: 200,
                    body: try Self.discoveryResponse(
                        bindingRange: 129 ..< 130,
                        nextCursor: nil,
                        revision: revision + 1
                    )
                ),
            ]
        }
        let transport = RecordingBrokerTransport(responses: responses)
        let client = try makeClient(transport: transport)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().count == 6)
    }

    @Test
    func discoveryKeepsLegacyUnpaginatedResponseBounded() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: try Self.discoveryResponse(bindingCount: 256)),
        ])
        let client = try makeClient(transport: transport)

        let discovery = try await client.discover()

        #expect(discovery.bindings.count == 256)
        #expect(await transport.requests().count == 1)
    }

    @Test
    func discoveryRejectsOversizedPaginatedResponse() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 130,
                    nextCursor: "cursor-1"
                )
            ),
        ])
        let client = try makeClient(transport: transport)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.discover()
        }
    }

    @Test
    func discoveryRejectsRepeatedCursorWithoutTotalPageCap() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 1 ..< 129,
                    nextCursor: "cursor-1"
                )
            ),
            .json(
                status: 200,
                body: try Self.discoveryResponse(
                    bindingRange: 129 ..< 257,
                    nextCursor: "cursor-1"
                )
            ),
        ])
        let client = try makeClient(transport: transport)

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.discover()
        }
    }

    @Test
    func connectivitySyncSendsKnownRevisionAndAcceptsUnchangedResponse() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: """
                {"protocol_version":2,"revision":41,"changed":false,"reset":false}
                """
            ),
        ])
        let client = try makeClient(transport: transport)

        let response = try await client.syncConnectivity(knownRevision: 41)

        #expect(response.revision == 41)
        #expect(!response.changed)
        #expect(response.snapshot == nil)
        let captured = try #require(await transport.requests().first)
        #expect(captured.url?.path == "/api/connectivity/v2/sync")
        #expect(captured.httpMethod == "POST")
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["protocol_version"] as? Int == 2)
        #expect(object["known_revision"] as? Int == 41)
    }

    @Test
    func connectivityInitialSyncEncodesExplicitNullRevision() async throws {
        let snapshot = try Self.discoveryObject(revision: 1)
        let responseBody = try Self.jsonString([
            "protocol_version": 2,
            "revision": 1,
            "changed": true,
            "reset": false,
            "snapshot": snapshot,
            "snapshot_complete": true,
        ])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: responseBody),
        ])
        let client = try makeClient(transport: transport)

        let response = try await client.syncConnectivity(knownRevision: nil)

        #expect(response.snapshotComplete == true)

        let captured = try #require(await transport.requests().first)
        let body = try #require(captured.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object.keys.contains("known_revision"))
        #expect(object["known_revision"] is NSNull)
    }

    @Test
    func connectivityV3SendsAndAcceptsOnlyTheEchoedScope() async throws {
        let scope = try iosDiscoveryScope()
        let snapshot = try Self.discoveryObject(revision: 2)
        let responseBody = try Self.jsonString([
            "protocol_version": 3,
            "revision": 2,
            "changed": true,
            "reset": false,
            "discovery_scope": try scopeObject(scope),
            "snapshot": snapshot,
            "snapshot_scope_complete": true,
        ])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: responseBody),
        ])
        let client = try makeClient(
            transport: transport,
            discoveryScope: scope
        )

        let response = try await client.syncConnectivity(knownRevision: nil)

        #expect(response.protocolVersion == 3)
        #expect(response.discoveryScope == scope)
        #expect(response.snapshotIsComplete)
        let request = try #require(await transport.requests().first)
        #expect(request.url?.path == "/api/connectivity/v3/sync")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["protocol_version"] as? Int == 3)
        #expect(object["discovery_scope"] != nil)
    }

    @Test(arguments: [Bool?.none, false])
    func connectivityV3RejectsChangedSnapshotWithoutScopedCompleteness(
        completeness: Bool?
    ) async throws {
        let scope = try iosDiscoveryScope()
        let snapshot = try Self.discoveryObject(revision: 2)
        var responseObject: [String: Any] = [
            "protocol_version": 3,
            "revision": 2,
            "changed": true,
            "reset": false,
            "discovery_scope": try scopeObject(scope),
            "snapshot": snapshot,
        ]
        if let completeness {
            responseObject["snapshot_scope_complete"] = completeness
        }
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: try Self.jsonString(responseObject)
            ),
        ])
        let client = try makeClient(
            transport: transport,
            discoveryScope: scope
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.syncConnectivity(knownRevision: nil)
        }
        #expect(await transport.requests().compactMap { $0.url?.path } == [
            "/api/connectivity/v3/sync",
        ])
    }

    @Test
    func scopedDiscoveryRejectsIncompleteV3WithoutFetchingGlobalBindings() async throws {
        let scope = try iosDiscoveryScope()
        let snapshot = try Self.discoveryObject(revision: 2)
        let responseBody = try Self.jsonString([
            "protocol_version": 3,
            "revision": 2,
            "changed": true,
            "reset": false,
            "discovery_scope": try scopeObject(scope),
            "snapshot": snapshot,
            "snapshot_scope_complete": false,
        ])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: responseBody),
        ])
        let client = try makeClient(
            transport: transport,
            discoveryScope: scope
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().compactMap { $0.url?.path } == [
            "/api/connectivity/v3/sync",
        ])
    }

    @Test
    func connectivityV3FallsBackToGlobalV2OnOlderServers() async throws {
        let snapshot = try Self.discoveryObject(revision: 2)
        let v2Response = try Self.jsonString([
            "protocol_version": 2,
            "revision": 2,
            "changed": true,
            "reset": false,
            "snapshot": snapshot,
            "snapshot_complete": true,
        ])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 404, body: #"{"error":"not_found"}"#),
            .json(status: 200, body: v2Response),
        ])
        let client = try makeClient(
            transport: transport,
            discoveryScope: iosDiscoveryScope()
        )

        let response = try await client.syncConnectivity(knownRevision: nil)

        #expect(response.protocolVersion == 2)
        #expect(response.snapshotComplete == true)
        let requests = await transport.requests()
        #expect(requests.compactMap { $0.url?.path } == [
            "/api/connectivity/v3/sync",
            "/api/connectivity/v2/sync",
        ])
        let v2Body = try #require(requests[1].httpBody)
        let v2Object = try #require(
            JSONSerialization.jsonObject(with: v2Body) as? [String: Any]
        )
        #expect(v2Object["discovery_scope"] == nil)
    }

    @Test
    func connectivitySyncRequiresAnAtomicSnapshotAtTheEnvelopeRevision() async throws {
        let snapshot = try Self.discoveryObject(revision: 42)
        let body = try Self.jsonString([
            "protocol_version": 2,
            "revision": 42,
            "changed": true,
            "reset": false,
            "snapshot": snapshot,
        ])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: body),
        ])
        let client = try makeClient(transport: transport)

        let response = try await client.syncConnectivity(knownRevision: 41)

        #expect(response.revision == 42)
        #expect(response.snapshot?.revision == 42)
        #expect(response.snapshot?.bindings.count == 1)
        #expect(response.snapshotComplete == nil)

        let mismatchedBody = try Self.jsonString([
            "protocol_version": 2,
            "revision": 43,
            "changed": true,
            "reset": false,
            "snapshot": snapshot,
        ])
        let mismatchedTransport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: mismatchedBody),
        ])
        let mismatchedClient = try makeClient(transport: mismatchedTransport)
        await #expect(throws: CmxIrohTrustBrokerClientError.invalidResponse) {
            _ = try await mismatchedClient.syncConnectivity(knownRevision: 42)
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

    private func iosDiscoveryScope() throws -> CmxConnectivityDiscoveryScope {
        try CmxConnectivityDiscoveryScope(
            deviceID: "123e4567-e89b-42d3-a456-426614174001",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "stable",
            platform: .ios,
            peerPlatform: .mac,
            peerTags: ["nightly", "default"],
            peerPairingEnabled: true
        )
    }

    private func scopeObject(
        _ scope: CmxConnectivityDiscoveryScope
    ) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(scope)
            ) as? [String: Any]
        )
    }

    private func registrationSigner() throws -> CmxIrohRegistrationSigner {
        try CmxIrohRegistrationSigner(
            identity: identityMaterial(),
            endpointID: Self.endpointID
        )
    }

    private func identityMaterial() throws -> CmxIrohIdentityMaterial {
        let secret = try CmxIrohSecretKey(bytes: Data((0 ..< 32).map(UInt8.init)))
        return try CmxIrohIdentityMaterial(
            secretKey: secret,
            generation: 1
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

    private static let tokenSource = CmxIrohBrokerTokenSource(
        credentialPair: {
            CmxIrohBrokerCredentials(accessToken: "access", refreshToken: "refresh")
        }
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
        try discoveryResponse(
            bindingRange: 1 ..< (bindingCount + 1),
            nextCursor: nil
        )
    }

    private static func discoveryResponse(
        bindingRange: Range<Int>,
        nextCursor: String?,
        revision: Int? = nil
    ) throws -> String {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(discoveryResponse.utf8)
            ) as? [String: Any]
        )
        let template = try #require((object["bindings"] as? [[String: Any]])?.first)
        object["bindings"] = bindingRange.map { index in
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
        if let nextCursor {
            object["next_cursor"] = nextCursor
        } else {
            object["next_cursor"] = NSNull()
        }
        if let revision {
            object["revision"] = revision
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func discoveryObject(revision: Int) throws -> [String: Any] {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(discoveryResponse.utf8)
            ) as? [String: Any]
        )
        object["revision"] = revision
        return object
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
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
