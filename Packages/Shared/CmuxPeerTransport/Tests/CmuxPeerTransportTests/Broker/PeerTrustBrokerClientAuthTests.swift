import Foundation
import Testing
@testable import CmuxPeerTransport

/// The auth boundary: single-snapshot capture, three-state token outcomes,
/// exactly-once 401 recovery, and error classification with Retry-After.
@Suite
struct PeerTrustBrokerClientAuthTests {
    @Test
    func unauthorizedRejectionReusesAnAlreadyRotatedPairWithoutRefreshing() async throws {
        let (stale, fresh) = BrokerFixtures.staleFreshCredentials
        let source = ScriptedTokenSource([stale, fresh])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 201, body: BrokerFixtures.challengeBody),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: source.provider
        )

        let response = try await client.challenge(try Self.challengeRequest())

        #expect(response.challengeID == "123e4567-e89b-42d3-a456-426614174000")
        #expect(await source.forceRefreshCount == 0)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(
            requests.first?.value(forHTTPHeaderField: "Authorization")
                == "Bearer stale-access"
        )
        #expect(
            requests.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer fresh-access"
        )
        #expect(
            requests.last?.value(forHTTPHeaderField: "X-Stack-Refresh-Token")
                == "fresh-refresh"
        )
    }

    @Test
    func unauthorizedRejectionForceRefreshesAnUnchangedPairExactlyOnce() async throws {
        let (stale, fresh) = BrokerFixtures.staleFreshCredentials
        let source = ScriptedTokenSource([stale, stale, fresh])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 201, body: BrokerFixtures.challengeBody),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: source.provider
        )

        _ = try await client.challenge(try Self.challengeRequest())

        #expect(await source.forceRefreshCount == 1)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(
            requests.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer fresh-access"
        )
    }

    @Test
    func repeatedUnauthorizedRejectionStopsAfterOneRetry() async throws {
        let (stale, fresh) = BrokerFixtures.staleFreshCredentials
        let source = ScriptedTokenSource([stale, fresh])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: source.provider
        )

        await #expect(throws: PeerBrokerError.unauthorized) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
        #expect(await transport.requests().count == 2)
    }

    @Test
    func unauthorizedRejectionWithNoReplacementPairPropagates() async throws {
        let (stale, _) = BrokerFixtures.staleFreshCredentials
        let source = ScriptedTokenSource([stale, nil])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: source.provider
        )

        await #expect(throws: PeerBrokerError.unauthorized) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
        #expect(await transport.requests().count == 1)
        // The recovery attempted its one refresh against the unchanged pair.
        #expect(await source.forceRefreshCount == 1)
    }

    @Test
    func forbiddenRejectionMapsToDeniedWithoutRecovery() async throws {
        let (stale, _) = BrokerFixtures.staleFreshCredentials
        let source = ScriptedTokenSource([stale])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 403, body: #"{"error":"forbidden","secret":"do-not-copy"}"#),
        ])
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: source.provider
        )

        await #expect(throws: PeerBrokerError.denied(statusCode: 403, code: "forbidden")) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
        #expect(await transport.requests().count == 1)
        #expect(await source.captureCount == 1)
        #expect(await source.forceRefreshCount == 0)
    }

    @Test
    func authRejectionsDoNotClearTheRetainedBindingProof() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 403, body: #"{"error":"forbidden"}"#),
        ])
        let authorization = try PeerBindingRequestAuthorization(
            bindingID: BrokerFixtures.bindingID,
            clientNamespace: "dev.cmux.app.internal",
            identity: BrokerFixtures.identity(),
            endpointID: BrokerFixtures.identity().endpointID
        )
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            bindingAuthorization: authorization
        )

        await #expect(throws: PeerBrokerError.unauthorized) {
            _ = try await client.discover()
        }
        #expect(await client.hasBindingAuthorization())
        await #expect(throws: PeerBrokerError.denied(statusCode: 403, code: "forbidden")) {
            _ = try await client.discover()
        }
        #expect(await client.hasBindingAuthorization())
        #expect(await client.bindingAuthorizationID() == BrokerFixtures.bindingID)
    }

    @Test
    func missingCredentialsFailClosedWithoutTouchingTheWire() async throws {
        let transport = RecordingBrokerTransport()
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: PeerBrokerTokenProvider(capture: { nil })
        )

        await #expect(throws: PeerBrokerError.unauthorized) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func throwingCredentialCaptureClassifiesAsConnectivity() async throws {
        struct TokenStoreBusy: Error {}
        let transport = RecordingBrokerTransport()
        let client = try BrokerFixtures.makeClient(
            transport: transport,
            tokenProvider: PeerBrokerTokenProvider(capture: { throw TokenStoreBusy() })
        )

        await #expect(throws: PeerBrokerError.connectivity) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func rateLimitedResponsePropagatesTheValidatedRetryAfterFloor() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 429,
                body: #"{"error":"rate_limited"}"#,
                headers: ["Retry-After": "120"]
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        do {
            _ = try await client.challenge(try Self.challengeRequest())
            Issue.record("Expected a rate-limit rejection")
        } catch let error as PeerBrokerError {
            #expect(error == .serverRateLimited(retryAfter: .seconds(120)))
            #expect(error.retryAfter == .seconds(120))
            #expect(!error.allowsOfflineGrantFallback)
        }
    }

    @Test(arguments: ["", "0", "-5", "12x", "086400000", "99999999"])
    func rateLimitedResponseDropsAnInvalidRetryAfterHeader(header: String) async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 429,
                body: #"{"error":"rate_limited"}"#,
                headers: header.isEmpty ? [:] : ["Retry-After": header]
            ),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        await #expect(throws: PeerBrokerError.serverRateLimited(retryAfter: nil)) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
    }

    @Test
    func networkFailuresClassifyAsConnectivityAndUnlockOfflineFallback() async throws {
        let transport = RecordingBrokerTransport(failure: URLError(.timedOut))
        let client = try BrokerFixtures.makeClient(transport: transport)

        do {
            _ = try await client.challenge(try Self.challengeRequest())
            Issue.record("Expected a connectivity failure")
        } catch let error as PeerBrokerError {
            #expect(error == .connectivity)
            #expect(error.allowsOfflineGrantFallback)
        }
    }

    @Test
    func cancelledTransportSurfacesCancellationNotAFailure() async throws {
        let transport = RecordingBrokerTransport(failure: URLError(.cancelled))
        let client = try BrokerFixtures.makeClient(transport: transport)

        await #expect(throws: CancellationError.self) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
    }

    @Test
    func serverFailuresAreDeniedTransientAndNeverUnlockOfflineFallback() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 500, body: #"{"error":"internal"}"#),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        do {
            _ = try await client.challenge(try Self.challengeRequest())
            Issue.record("Expected a server failure")
        } catch let error as PeerBrokerError {
            #expect(error == .denied(statusCode: 500, code: "internal"))
            #expect(error.isTransient)
            #expect(!error.allowsOfflineGrantFallback)
        }
    }

    @Test
    func undecodableSuccessBodyClassifiesAsProtocolError() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 200, body: #"{"unexpected":"shape"}"#),
        ])
        let client = try BrokerFixtures.makeClient(transport: transport)

        await #expect(throws: PeerBrokerError.protocolError) {
            _ = try await client.challenge(try Self.challengeRequest())
        }
    }

    @Test
    func cleartextNonLoopbackBaseURLIsRejectedAtConstruction() async throws {
        #expect(throws: PeerBrokerError.protocolError) {
            _ = try PeerTrustBrokerClient(
                baseURL: URL(string: "http://cmux.example")!,
                tokenProvider: PeerBrokerTokenProvider(capture: { nil }),
                clientNamespace: "legacy",
                transport: RecordingBrokerTransport()
            )
        }
    }

    private static func challengeRequest() throws -> PeerBrokerChallengeRequest {
        try BrokerFixtures.signer().prepare(
            payload: BrokerFixtures.registrationPayload()
        ).challengeRequest
    }
}
