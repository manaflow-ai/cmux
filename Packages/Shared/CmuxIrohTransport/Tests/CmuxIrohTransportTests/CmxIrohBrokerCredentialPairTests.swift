import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

/// A credential source whose snapshots rotate between pair reads. The atomic
/// `pair()` reader returns one snapshot's tokens together, so a request built
/// from it is always consistent; the count proves how many captures a request
/// performed.
private final class RotatingCredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [(access: String, refresh: String)]
    private var index = 0
    private var pairReads = 0

    init(_ snapshots: [(access: String, refresh: String)]) {
        self.snapshots = snapshots
    }

    /// Both tokens from ONE snapshot; the NEXT read observes the next snapshot,
    /// modeling a force refresh landing between two captures.
    func pair() -> CmxIrohBrokerCredentials {
        lock.withLock {
            pairReads += 1
            let snapshot = snapshots[min(index, snapshots.count - 1)]
            index = min(index + 1, snapshots.count - 1)
            return CmxIrohBrokerCredentials(
                accessToken: snapshot.access,
                refreshToken: snapshot.refresh
            )
        }
    }

    var pairReadCount: Int { lock.withLock { pairReads } }
}

/// Regression coverage for the broker assembling one request from a single
/// credential snapshot. The broker must not read the access and refresh tokens
/// through two independent captures: a force refresh between them can pair an
/// old access token with a rotated refresh token (or vice versa), which the
/// server rejects. `credentialPair` — the token source's ONLY construction
/// input — supplies both tokens from one capture, and each request must
/// perform exactly one capture.
@Suite(.serialized)
struct CmxIrohBrokerCredentialPairTests {
    @Test
    func credentialDescriptionsRedactBothTokens() {
        let credentials = CmxIrohBrokerCredentials(
            accessToken: "access-secret",
            refreshToken: "refresh-secret"
        )

        for rendered in [String(describing: credentials), String(reflecting: credentials)] {
            #expect(rendered.contains("<redacted>"))
            #expect(!rendered.contains("access-secret"))
            #expect(!rendered.contains("refresh-secret"))
        }
    }

    @Test
    func revokeSendsOneConsistentCredentialSnapshot() async throws {
        let box = RotatingCredentialBox([
            (access: "access-0", refresh: "refresh-0"),
            (access: "access-1", refresh: "refresh-1"),
        ])
        let tokenSource = CmxIrohBrokerTokenSource(
            credentialPair: { box.pair() }
        )
        let transport = RecordingBrokerTransport(responses: [
            .json(
                status: 200,
                body: #"{"revoked":true,"lan_rendezvous_rotated":true}"#
            ),
        ])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: tokenSource,
            clientNamespace: "legacy",
            transport: transport
        )

        try await client.revoke(bindingID: "123e4567-e89b-42d3-a456-426614174010")

        // The request performed exactly ONE atomic capture.
        #expect(box.pairReadCount == 1)
        let captured = try #require(await transport.requests().first)
        // Both header values come from the SAME snapshot (index 0), so an old
        // access token is never paired with a rotated refresh token.
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer access-0")
        #expect(captured.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh-0")
    }
}
