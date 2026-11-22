@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// #32724: on a loaded Mac the read barrier's daemon round trip (`after: "sync"`) took longer
/// than the request's 2 s deadline, and `cmux cloud start-chat` failed with "timed out:
/// identify (no reply within 2.0 seconds)" while app and daemon were healthy. The round trip now
/// has no wall clock, the request's own deadline starts after it, and a barrier that fails says
/// nothing ran, so the CLI asks again instead of showing the error.
@Suite(.timeLimit(.minutes(1))) struct SyncBarrierUnderLoadTests {
    static let deadline: Duration = .milliseconds(100)

    func makeRouter(barrier: @escaping @Sendable () async throws -> UInt64) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(),
                                   configuration: ControlRouter.Configuration(requestDeadline: Self.deadline))
        // A loaded topology at daemon sequence 0: the barrier's sequence is then already reflected,
        // so the test measures the barrier's wait, not a snapshot that never loads.
        router.snapshots.publish { $0.topology.isLoaded = true }
        router.registerSyncBarrier(barrier)
        return router
    }

    @Test func aBarrierSlowerThanTheRequestDeadlineStillAnswers() async throws {
        let router = makeRouter {
            try await Task.sleep(for: .milliseconds(500))
            return 0
        }
        let started = ContinuousClock.now
        let answer = await router.handle(ControlRequest(id: "1", method: "snapshot.get", params: ["after": "sync"]))
        let value = try answer.get()
        #expect(value["sequence"] != nil)
        #expect(ContinuousClock.now - started >= .milliseconds(500))
    }

    @Test func aFailedBarrierSaysNothingRanSoTheCLIAsksAgain() async {
        struct Lost: Error {}
        let router = makeRouter { throw Lost() }
        let answer = await router.handle(ControlRequest(id: "1", method: "snapshot.get", params: ["after": "sync"]))
        guard case .failure(let error) = answer else {
            Issue.record("a failed barrier answered \(answer)")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.data?["not_run"]?.boolValue == true)
        #expect(error.data?["state"]?.stringValue == "not_run")
    }
}
