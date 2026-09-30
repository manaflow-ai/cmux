import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Closing the last tab of a workspace closes the workspace (dogfood
/// nxdog9), whatever closed it: Cmd-W, the tab's x, the CLI, or the
/// process exiting. Only a workspace that is empty the first time this
/// connection sees it (a hard daemon kill, another client creating it
/// empty) gets a new terminal.
@MainActor
struct EmptiedWorkspaceTests {
    final class Recorder {
        var created: [WorkspaceKey] = []
        var closed: [WorkspaceKey] = []
    }

    private static let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02")

    private static func services() throws -> (AppServices, Recorder) {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let recorder = Recorder()
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { key in
            recorder.created.append(key)
            return SurfaceID(rawValue: 42)
        }
        services.emptyWorkspaces.close = { key in recorder.closed.append(key) }
        return (services, recorder)
    }

    /// The daemon's tree after the workspace's last tab closed.
    private static func emptied(_ revision: UInt64 = 2) -> DaemonTree {
        DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "w")])
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func shownWorkspaceWhoseLastTabClosedIsClosedNotRefilled() async throws {
        let (services, recorder) = try Self.services()
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        services.daemon.store.apply(snapshot: Self.emptied())
        controller.applyCurrent()
        controller.applyCurrent()
        await Self.settle { !recorder.closed.isEmpty }
        await Self.settle { false }
        #expect(recorder.closed == [Self.key])
        #expect(recorder.created.isEmpty)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// No window shows it (another workspace is selected): its last process
    /// exited, and it closes all the same.
    @Test func hiddenWorkspaceWhoseLastTabClosedIsClosed() async throws {
        let (services, recorder) = try Self.services()
        await Self.settle { false }
        services.daemon.store.apply(snapshot: Self.emptied())
        await Self.settle { !recorder.closed.isEmpty }
        await Self.settle { false }
        #expect(recorder.closed == [Self.key])
        #expect(recorder.created.isEmpty)
        withExtendedLifetime(services) {}
    }

    /// What was seen counts only on its own connection: after a daemon
    /// restart an empty workspace is one the restart emptied, and gets a
    /// terminal, even though the observer never saw a state in between.
    @Test func workspaceEmptyAfterAReconnectIsRepaired() async throws {
        let (services, recorder) = try Self.services()
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        // The mirror keeps the old tree until the new connection's snapshot.
        services.daemon.store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .disconnected(reason: "daemon killed"))])
        await Self.settle { false }
        services.daemon.store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .connected(DaemonIdentity(generation: "g2"), generationChanged: true))])
        services.daemon.store.apply(snapshot: Self.emptied())
        controller.applyCurrent()
        await Self.settle { !recorder.created.isEmpty }
        #expect(recorder.created == [Self.key])
        #expect(recorder.closed.isEmpty)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// A failed close leaves the workspace open and empty: it gets a
    /// terminal instead of a close retried on every change.
    @Test func failedCloseFallsBackToARepair() async throws {
        let (services, recorder) = try Self.services()
        struct Boom: Error {}
        services.emptyWorkspaces.close = { key in recorder.closed.append(key); throw Boom() }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        services.daemon.store.apply(snapshot: Self.emptied())
        controller.applyCurrent()
        await Self.settle { !recorder.closed.isEmpty }
        await Self.settle { false }
        controller.applyCurrent()
        await Self.settle { !recorder.created.isEmpty }
        #expect(recorder.closed == [Self.key])
        #expect(recorder.created == [Self.key])
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }
}
