@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `action.run` against a loaded topology: a target that names nothing is
/// `not_found` before any handler runs, so `workspace rename --target <typo>`
/// cannot report success (plans/cmux-next/state-ownership.md 4.3).
@Suite struct ActionRunTargetTests {
    func makeRouter(_ executor: RecordingExecutor) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        router.snapshots.publish { snapshot in
            snapshot = ControlSnapshot.sample()
        }
        return router
    }

    @Test func anUnknownTargetInALoadedTopologyIsNotFound() async {
        let executor = RecordingExecutor()
        let router = makeRouter(executor)
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "workspaceGroup.collapse", "target": "workspace-group:grp_missing", "wait": false,
        ]))
        guard case .failure(let error) = result else {
            Issue.record("an unknown target ran the handler: \(result)")
            return
        }
        #expect(error.code == "not_found")
        #expect(executor.requests.withLock { $0.isEmpty })
    }
}
