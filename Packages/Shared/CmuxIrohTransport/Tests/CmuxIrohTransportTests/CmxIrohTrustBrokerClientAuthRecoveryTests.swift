import Foundation
import Testing
@testable import CmuxIrohTransport

/// The broker client's exactly-once credential recovery: a pair that was
/// coherent at capture can still be rejected when another lane rotates the
/// session between capture and server validation (the wake-time RPC force
/// refresh, most commonly). One retry with a pair minted after the rejection
/// absorbs the race; a second rejection is authoritative.
@Suite(.serialized)
struct CmxIrohTrustBrokerClientAuthRecoveryTests {
    private actor AccountSnapshotSource {
        private var snapshots: [CmxIrohAccountCredentialSnapshot]
        private var lastSnapshot: CmxIrohAccountCredentialSnapshot?
        private(set) var forceRefreshCount = 0

        init(_ snapshots: [CmxIrohAccountCredentialSnapshot]) {
            self.snapshots = snapshots
            self.lastSnapshot = snapshots.last
        }

        func snapshot() -> CmxIrohAccountCredentialSnapshot? {
            guard !snapshots.isEmpty else { return lastSnapshot }
            let next = snapshots.removeFirst()
            lastSnapshot = next
            return next
        }

        func forceRefresh() {
            forceRefreshCount += 1
        }
    }

    private actor RecoveryRecorder {
        private(set) var rejectedPairs: [CmxIrohBrokerCredentials] = []
        private let recovered: CmxIrohBrokerCredentials?

        init(recovered: CmxIrohBrokerCredentials?) {
            self.recovered = recovered
        }

        func recover(
            _ rejected: CmxIrohBrokerCredentials
        ) -> CmxIrohBrokerCredentials? {
            rejectedPairs.append(rejected)
            return recovered
        }
    }

    @Test
    func unauthorizedRejectionRetriesOnceWithRecoveredPair() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 201, body: Self.challengeBody),
        ])
        let recorder = RecoveryRecorder(recovered: CmxIrohBrokerCredentials(
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh"
        ))
        let client = try makeClient(transport: transport, recorder: recorder)

        let response = try await client.issueChallenge(try Self.challengeRequest)

        #expect(response.challengeID == "123e4567-e89b-42d3-a456-426614174000")
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests.first?.value(
            forHTTPHeaderField: "Authorization"
        ) == "Bearer stale-access")
        #expect(requests.last?.value(
            forHTTPHeaderField: "Authorization"
        ) == "Bearer fresh-access")
        #expect(requests.last?.value(
            forHTTPHeaderField: "X-Stack-Refresh-Token"
        ) == "fresh-refresh")
        let rejected = await recorder.rejectedPairs
        #expect(rejected.count == 1)
        #expect(rejected.first?.accessToken == "stale-access")
        #expect(rejected.first?.refreshToken == "stale-refresh")
    }

    @Test
    func unauthorizedRejectionWithoutRecoveryPropagates() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
        ])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(credentialPair: {
                CmxIrohBrokerCredentials(
                    accessToken: "stale-access",
                    refreshToken: "stale-refresh"
                )
            }),
            clientNamespace: "legacy",
            transport: transport
        )

        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        )) {
            _ = try await client.issueChallenge(try Self.challengeRequest)
        }
        #expect(await transport.requests().count == 1)
    }

    @Test
    func repeatedUnauthorizedRejectionStopsAfterOneRetry() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
        ])
        let recorder = RecoveryRecorder(recovered: CmxIrohBrokerCredentials(
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh"
        ))
        let client = try makeClient(transport: transport, recorder: recorder)

        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 401,
            code: "unauthorized"
        )) {
            _ = try await client.issueChallenge(try Self.challengeRequest)
        }
        #expect(await transport.requests().count == 2)
        #expect(await recorder.rejectedPairs.count == 1)
    }

    @Test
    func forbiddenRejectionDoesNotInvokeRecovery() async throws {
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 403, body: #"{"error":"forbidden"}"#),
        ])
        let recorder = RecoveryRecorder(recovered: CmxIrohBrokerCredentials(
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh"
        ))
        let client = try makeClient(transport: transport, recorder: recorder)

        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(
            statusCode: 403,
            code: "forbidden"
        )) {
            _ = try await client.issueChallenge(try Self.challengeRequest)
        }
        #expect(await transport.requests().count == 1)
        #expect(await recorder.rejectedPairs.isEmpty)
    }

    @Test
    func sharedAccountPinnedSourceReusesAnAlreadyRotatedPair() async throws {
        let stale = Self.accountSnapshot(
            accountID: "account-a",
            accessToken: "stale-access"
        )
        let fresh = Self.accountSnapshot(
            accountID: "account-a",
            accessToken: "fresh-access"
        )
        let snapshots = AccountSnapshotSource([stale, fresh])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 201, body: Self.challengeBody),
        ])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: .accountPinned(
                to: "account-a",
                snapshot: { await snapshots.snapshot() },
                forceRefresh: { await snapshots.forceRefresh() }
            ),
            clientNamespace: "legacy",
            transport: transport
        )

        _ = try await client.issueChallenge(try Self.challengeRequest)

        #expect(await snapshots.forceRefreshCount == 0)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func sharedAccountPinnedSourceForceRefreshesAnUnchangedRejectedPairOnce() async throws {
        let stale = Self.accountSnapshot(
            accountID: "account-a",
            accessToken: "stale-access"
        )
        let fresh = Self.accountSnapshot(
            accountID: "account-a",
            accessToken: "fresh-access"
        )
        let snapshots = AccountSnapshotSource([stale, stale, fresh])
        let transport = RecordingBrokerTransport(responses: [
            .json(status: 401, body: #"{"error":"unauthorized"}"#),
            .json(status: 201, body: Self.challengeBody),
        ])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: .accountPinned(
                to: "account-a",
                snapshot: { await snapshots.snapshot() },
                forceRefresh: { await snapshots.forceRefresh() }
            ),
            clientNamespace: "legacy",
            transport: transport
        )

        _ = try await client.issueChallenge(try Self.challengeRequest)

        #expect(await snapshots.forceRefreshCount == 1)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func cachedPolicyRecoveryFailsClosedForAuthRejections() {
        #expect(CmxIrohClientRuntime.recoversWithCachedPolicy(
            CmxIrohTrustBrokerClientError.connectivity
        ))
        #expect(!CmxIrohClientRuntime.recoversWithCachedPolicy(
            CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        ))
        #expect(!CmxIrohClientRuntime.recoversWithCachedPolicy(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: nil)
        ))
        #expect(!CmxIrohClientRuntime.recoversWithCachedPolicy(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 500, code: nil)
        ))
        #expect(!CmxIrohClientRuntime.recoversWithCachedPolicy(
            CmxIrohTrustBrokerClientError.invalidResponse
        ))
    }

    private func makeClient(
        transport: RecordingBrokerTransport,
        recorder: RecoveryRecorder
    ) throws -> CmxIrohTrustBrokerClient {
        try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                credentialPair: {
                    CmxIrohBrokerCredentials(
                        accessToken: "stale-access",
                        refreshToken: "stale-refresh"
                    )
                },
                recoveredCredentialPair: { rejected in
                    await recorder.recover(rejected)
                }
            ),
            clientNamespace: "legacy",
            transport: transport
        )
    }

    private static let challengeBody =
        #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#

    private static let endpointID =
        "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"

    private static var challengeRequest: CmxIrohChallengeRequest {
        get throws {
            let secret = try CmxIrohSecretKey(
                bytes: Data((0 ..< 32).map(UInt8.init))
            )
            let identity = try CmxIrohIdentityMaterial(
                secretKey: secret,
                generation: 1
            )
            let signer = try CmxIrohRegistrationSigner(
                identity: identity,
                endpointID: endpointID
            )
            let payload = try CmxIrohRegistrationPayload(
                deviceID: "123e4567-e89b-42d3-a456-426614174001",
                appInstanceID: "123e4567-e89b-42d3-a456-426614174002",
                tag: "stable",
                platform: .ios,
                endpointID: endpointID,
                identityGeneration: 1,
                pairingEnabled: false,
                capabilities: ["control"],
                pathHints: [],
                now: Date(timeIntervalSince1970: 1_782_000_000)
            )
            return try signer.prepare(payload: payload).challengeRequest
        }
    }

    private static func accountSnapshot(
        accountID: String,
        accessToken: String
    ) -> CmxIrohAccountCredentialSnapshot {
        CmxIrohAccountCredentialSnapshot(
            accountID: accountID,
            credentials: CmxIrohBrokerCredentials(
                accessToken: accessToken,
                refreshToken: "\(accessToken)-refresh"
            )
        )
    }
}
