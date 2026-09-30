import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A workspace with no screens (after a hard daemon kill) must not render an
/// empty content area: the window asks for one terminal and focuses it.
@MainActor
struct EmptyWorkspaceTests {
    final class Recorder { var keys: [WorkspaceKey] = [] }

    private static let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a01")

    private static func services(workspaces: [WorkspaceSnapshot]) -> (AppServices, Recorder) {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: workspaces))
        let recorder = Recorder()
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { key in
            recorder.keys.append(key)
            return SurfaceID(rawValue: 42)
        }
        return (services, recorder)
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func emptyWorkspaceGetsExactlyOneTerminal() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "empty")])
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { controller.focus.state.expectation != nil }
        // Re-applying the still-empty tree (the delta has not landed) must not ask again.
        controller.applyCurrent()
        controller.applyCurrent()
        await Self.settle { false }
        #expect(recorder.keys == [Self.key])
        // The new terminal is focused once the daemon reports it.
        #expect(controller.focus.state.expectation?.key == .surface("42"))
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    @Test func populatedWorkspaceIsLeftAlone() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let tree = try BridgeTreeFixture.tree()
        services.daemon.store.apply(snapshot: tree)
        let recorder = Recorder()
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { recorder.keys.append($0); return nil }
        let workspace = try #require(services.daemon.store.workspaces.first { !$0.screens.isEmpty })
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        #expect(recorder.keys.isEmpty)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    @Test func disconnectedDaemonIsNotAsked() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "empty")])
        services.emptyWorkspaces.canCreate = { false }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        #expect(recorder.keys.isEmpty)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    @Test func failedCreationIsRetriedOnTheNextChange() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "empty")])
        struct Boom: Error {}
        services.emptyWorkspaces.create = { key in recorder.keys.append(key); throw Boom() }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { recorder.keys.count == 1 }
        await Self.settle { false }
        controller.applyCurrent()
        await Self.settle { recorder.keys.count == 2 }
        #expect(recorder.keys.count == 2)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }
}

/// A populated tree for tests that need real panes.
enum BridgeTreeFixture {
    static func tree() throws -> DaemonTree {
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[{"kind":"pty","name":"t","surface":4,"dead":false}]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }
}
