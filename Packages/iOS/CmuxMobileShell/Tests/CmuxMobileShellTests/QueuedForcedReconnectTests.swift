import CmuxMobileRPC
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test(.timeLimit(.minutes(1)))
    func queuedForcedRetrySurvivesBackgroundBeforeItStarts() async throws {
        let readiness = TestMobileConnectionReadiness(permitsConnection: true)
        let base = KindRecordingTransportFactory(router: LivenessHostRouter(), box: TransportBox())
        let starts = AsyncStream<Int>.makeStream()
        let factory = ObservedReconnectTransportFactory(base: base) {
            starts.continuation.yield(base.attemptedKinds().count)
        }
        let runtime = LivenessTestRuntime(connectionReadiness: readiness,
            transportFactory: factory, now: Date.init, supportedRouteKinds: [.iroh])
        let shell = try await makeReconnectStore(routes: [try iroh()], runtime: runtime)
        defer { shell.signOut(); starts.continuation.finish() }
        #expect(await shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let initialDials = base.attemptedKinds().count

        shell.pendingForcedStoredMacReconnect = true
        shell.finishStoredMacReconnectAttempt(generation: shell.storedMacReconnectGeneration)
        // The queued launch has not received an actor turn. Backgrounding must
        // cancel that launch and retain its explicit replacement intent.
        readiness.publish(false)
        shell.suspendForegroundRefresh()
        let stopped = Task<Bool, any Error> {
            while shell.isReconnectingStoredMac {
                await withCheckedContinuation { continuation in
                    withObservationTracking { _ = shell.isReconnectingStoredMac } onChange: {
                        continuation.resume()
                    }
                }
            }
            return true
        }
        let settled = try? await RPCTaskTimeout().value(stopped, timeoutNanoseconds: 5_000_000_000)
        #expect(settled == true)
        #expect(shell.pendingForcedStoredMacReconnect)
        #expect(base.attemptedKinds().count == initialDials)
        #expect(shell.hasActiveMacConnection)

        readiness.publish(true)
        shell.resumeForegroundRefresh()
        let replacement = Task<Bool, any Error> {
            for await count in starts.stream where count > initialDials { return true }
            return false
        }
        let retried = try? await RPCTaskTimeout().value(replacement, timeoutNanoseconds: 5_000_000_000)
        #expect(retried == true, "foreground must perform the queued forced replacement of the healthy client")
        replacement.cancel()
        stopped.cancel()
    }
}
