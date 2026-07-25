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
}
