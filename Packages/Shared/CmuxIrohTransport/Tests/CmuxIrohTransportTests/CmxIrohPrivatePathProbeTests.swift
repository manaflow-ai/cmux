import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohPrivatePathProbeTests {
    @Test
    func reachableRequiresSuccessfulFakeDial() async {
        let result = await CmxIrohPrivatePathProbe(
            dial: {},
            now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        ).run(timeout: .seconds(1))

        #expect(result == .reachable(latencyMilliseconds: 0))
    }

    @Test
    func deadlineClassifiesTimeoutAndCancelsFakeDial() async {
        let result = await CmxIrohPrivatePathProbe(
            dial: {
                try await Task.sleep(for: .seconds(60))
            },
            sleep: { _ in }
        ).run(timeout: .seconds(1))

        #expect(result == .unreachable(.timedOut))
    }

    @Test
    func wrongPeerFromFakeDialIsNeverReachable() async {
        let result = await CmxIrohPrivatePathProbe(
            dial: {
                throw CmxIrohPrivatePathProbeDialError.wrongPeer
            },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        ).run(timeout: .seconds(1))

        #expect(result == .unreachable(.wrongPeer))
    }

    @Test
    func stalePortFromFakeDialHasSpecificClassification() async {
        let result = await CmxIrohPrivatePathProbe(
            dial: {
                throw CmxIrohPrivatePathProbeDialError.stalePort
            },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        ).run(timeout: .seconds(1))

        #expect(result == .unreachable(.stalePort))
    }

    @Test
    func mismatchedSelectedPathIsNeverReachable() async throws {
        let connection = TestIrohConnection(
            remoteIdentity: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "ab", count: 32)
            ),
            bidirectionalStreams: [],
            pathSnapshots: [
                CmxIrohConnectionPathSnapshot(
                    isSelected: true,
                    remoteAddress: "192.168.1.40:50909",
                    isIP: true,
                    isRelay: false
                ),
            ]
        )
        let verifier = CmxIrohPrivatePathSelectedPathVerifier(sleep: { _ in })

        let result = await CmxIrohPrivatePathProbe(
            dial: {
                try await verifier.verify(
                    connection: connection,
                    expectedRemoteAddress: "10.0.0.9:50909"
                )
            },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        ).run(timeout: .seconds(1))

        #expect(result == .unreachable(.pathMismatch))
    }

    @Test
    func matchingSelectedPathAfterSettleIsReachable() async throws {
        let connection = TestIrohConnection(
            remoteIdentity: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "cd", count: 32)
            ),
            bidirectionalStreams: [],
            pathSnapshots: [
                CmxIrohConnectionPathSnapshot(
                    isSelected: true,
                    remoteAddress: "https://relay.example.test",
                    isIP: false,
                    isRelay: true
                ),
            ]
        )
        let verifier = CmxIrohPrivatePathSelectedPathVerifier { _ in
            await connection.setConnectionPathSnapshots([
                CmxIrohConnectionPathSnapshot(
                    isSelected: true,
                    remoteAddress: "fd00::9:50909",
                    isIP: true,
                    isRelay: false
                ),
            ])
        }

        try await verifier.verify(
            connection: connection,
            expectedRemoteAddress: "[fd00::9]:50909"
        )
    }
}
