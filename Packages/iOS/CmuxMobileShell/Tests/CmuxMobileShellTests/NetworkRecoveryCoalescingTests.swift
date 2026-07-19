import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func repeatedPathChangeDuringReconnectRunsTrailingAttempt() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let reachability = ControllablePathChangeReachability()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [],
            holdFirstFailingPort: 51002
        )
        let store = try await makeReconnectStore(
            routes: [try loopbackRoute(id: "settling-network", port: 51002)],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            ),
            reachability: reachability
        )
        store.startObservingNetworkPathChanges()

        reachability.emitPathChange()
        let firstAttemptStarted = try await pollUntil {
            factory.attemptedPorts() == [51002]
        }
        #expect(firstAttemptStarted)
        let firstBoundaryScope = store.manualHostRPCAuthScope
        reachability.emitPathChange()
        let secondBoundaryApplied = try await pollUntil {
            store.manualHostRPCAuthScope != firstBoundaryScope
        }
        #expect(secondBoundaryApplied)
        factory.releaseHeldConnect()
        let connected = try await pollUntil {
            store.connectionState == .connected
        }

        #expect(connected)
        // The held first dial fails on release, so reaching .connected proves
        // the path change that landed mid-attempt was not dropped: the parked
        // trailing recovery re-dialed the same (only) route. The exact dial
        // count is an implementation detail of the recovery owner.
        let ports = factory.attemptedPorts()
        #expect(Set(ports) == [51_002])
        #expect(ports.count >= 2)
    }
}
