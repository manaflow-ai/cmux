import CmuxCloud
import CmuxSurfaceCatalogModel
import Testing

@Suite("Cloud terminal pruning")
struct CloudTerminalPrunerTests {
    private let machine = SurfaceMachineID.cloud("prune-fixture")

    @Test("selects only live detached terminals")
    func selectsDetachedTerminals() {
        let running = resource(key: "running", lifecycle: .running, views: [])
        let exited = resource(key: "exited", lifecycle: .exited, views: [])
        let attached = resource(key: "attached", lifecycle: .running, views: [view()])

        #expect(CloudTerminalPruner(resources: [running, exited, attached]).candidateIDs == [running.id])
    }

    @Test("retains ordinary close failures while cancellation throws")
    func reportsFailures() async throws {
        let first = resource(key: "first", lifecycle: .running, views: [])
        let second = resource(key: "second", lifecycle: .running, views: [])
        let result = try await CloudTerminalPruner(resources: [first, second]).run { id in
            if id == second.id { throw TestError.failed }
        }
        #expect(result.closed == [first.id])
        #expect(result.failed == [second.id.key])
    }

    private func resource(
        key: String,
        lifecycle: SurfaceLifecycle,
        views: [SurfaceRemoteView]
    ) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key),
            title: key,
            detail: nil,
            lifecycle: lifecycle,
            remoteViews: views
        )
    }

    private func view() -> SurfaceRemoteView {
        SurfaceRemoteView(
            tabID: "tab",
            workspace: SurfaceRemoteWorkspace(id: "workspace", name: "Workspace", index: 0, focused: false),
            screenIndex: 0,
            paneIndex: 0
        )
    }

    private enum TestError: Error { case failed }
}
