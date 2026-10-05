import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Closing the last tab of a workspace closes the workspace (dogfood
/// nxdog9), whatever closed it: Cmd-W, the tab's x, the CLI, or the
/// process exiting. A genuinely new empty workspace stays on its action
/// surface; a host that lost a terminal is refilled after a reconnect.
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
        services.emptyWorkspaces.cause = { _ in .tabClosed }
        return (services, recorder)
    }

    /// The daemon's tree after the workspace's last tab closed.
    private static func emptied(_ revision: UInt64 = 2) -> DaemonTree {
        DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "w")])
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// The launch snapshot drew the workspace with its pane before the
    /// daemon answered; the live tree then shows it empty (the daemon
    /// restarted without its terminals). No connection saw it with a pane,
    /// so it is repaired, not closed.
    @Test func workspaceDrawnFromTheLaunchSnapshotIsRepairedNotClosed() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let recorder = Recorder()
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { key in
            recorder.created.append(key)
            return SurfaceID(rawValue: 42)
        }
        services.emptyWorkspaces.close = { key in recorder.closed.append(key) }
        services.daemon.store.applyProvisional(snapshot: try BridgeTreeFixture.tree())
        let workspace = try #require(services.daemon.store.workspaces.first { $0.key == Self.key })
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        controller.applyCurrent()
        await Self.settle { false }
        services.daemon.store.apply(snapshot: Self.emptied())
        controller.applyCurrent()
        await Self.settle { !recorder.created.isEmpty }
        await Self.settle { false }
        #expect(recorder.closed.isEmpty)
        #expect(recorder.created == [Self.key])
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// The snapshot and the live tree agree (nothing changes when the store
    /// turns live), so a genuinely new empty workspace stays on its action
    /// surface until New is pressed. A populated one still closes when its
    /// last tab closes.
    @Test func turningLiveWithAnUnchangedTreeRunsTheChecks() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let recorder = Recorder()
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { key in
            recorder.created.append(key)
            return SurfaceID(rawValue: 42)
        }
        services.emptyWorkspaces.close = { key in recorder.closed.append(key) }
        let empty = Self.emptied(1)
        services.daemon.store.applyProvisional(snapshot: empty)
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        #expect(recorder.created.isEmpty, "nothing is repaired from the snapshot")
        services.daemon.store.apply(snapshot: empty)
        await Self.settle { false }
        #expect(recorder.created.isEmpty)
        #expect(recorder.closed.isEmpty)
        controller.emptyView.onNew?()
        await Self.settle { !recorder.created.isEmpty }
        #expect(recorder.created == [Self.key])
        controller.teardown()

        let populated = ActionBindingCoverageTests.boundServices()
        let closer = Recorder()
        populated.emptyWorkspaces.canCreate = { true }
        populated.emptyWorkspaces.create = { key in
            closer.created.append(key)
            return SurfaceID(rawValue: 42)
        }
        populated.emptyWorkspaces.close = { key in closer.closed.append(key) }
        populated.emptyWorkspaces.cause = { _ in .tabClosed }
        let tree = try BridgeTreeFixture.tree()
        populated.daemon.store.applyProvisional(snapshot: tree)
        populated.daemon.store.apply(snapshot: tree)
        await Self.settle { false }
        populated.daemon.store.apply(snapshot: Self.emptied(tree.workspaceRevision + 1))
        await Self.settle { !closer.closed.isEmpty }
        #expect(closer.closed == [Self.key], "its last tab closed on this connection")
        #expect(closer.created.isEmpty)
        withExtendedLifetime((services, populated, state)) {}
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

    /// tag nxthm: a relaunch found one terminal host dead only after the
    /// app had seen its workspace with the tab (asynchronous adoption,
    /// `host-process-ended-before-adoption`), and the last-tab rule closed
    /// the workspace: the user's workspace was gone. A lost terminal keeps
    /// its workspace and gets a new terminal.
    @Test func workspaceWhoseLastTerminalWasLostIsKeptAndRefilled() async throws {
        let (services, recorder) = try Self.services()
        services.emptyWorkspaces.cause = { _ in .terminalLost }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        await Self.settle { false }
        services.daemon.store.apply(snapshot: Self.emptied())
        controller.applyCurrent()
        await Self.settle { !recorder.created.isEmpty || !recorder.closed.isEmpty }
        await Self.settle { false }
        #expect(recorder.closed.isEmpty)
        #expect(recorder.created == [Self.key])
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }
}
