import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A workspace created empty shows its actions until New is pressed. Lost
/// terminals are covered by EmptiedWorkspaceTests separately.
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

    @Test func emptyWorkspaceWaitsForNewAndCreatesExactlyOneTab() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "empty")])
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        controller.applyCurrent()
        controller.applyCurrent()
        await Self.settle { false }
        #expect(recorder.keys.isEmpty)
        #expect(controller.focus.state.expectation == nil)
        let actions = try #require(controller.emptyView)
        #expect(controller.contentView.emptyView === actions)
        // Repeated New presses while the pane delta is in flight create once.
        actions.onNew?()
        actions.onNew?()
        await Self.settle { controller.focus.state.expectation != nil }
        controller.applyCurrent()
        actions.onNew?()
        await Self.settle { false }
        #expect(recorder.keys == [Self.key])
        // This harness uses the terminal fallback when no agent host is bound.
        #expect(controller.focus.state.expectation?.key == .surface("42"))
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// The store's home workspace starts empty on purpose (workspace-kind-v1):
    /// HomeService gives it the Chief conversation tab, never a terminal
    /// (homenat7 snapshot: Home opened on a stray terminal).
    @Test func theEmptyHomeWorkspaceGetsNoTerminal() async throws {
        var home = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "Home")
        home.kind = "home"
        let (services, recorder) = Self.services(workspaces: [home])
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        controller.applyCurrent()
        await Self.settle { !recorder.keys.isEmpty }
        #expect(recorder.keys.isEmpty)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// The app's own create-workspace + create-terminal answered, but the
    /// terminal's pane delta has not reached the mirror yet: the workspace
    /// still looks empty and must not get a second terminal.
    @Test func workspaceTheAppPopulatedIsNotRepairedBeforeItsDeltaLands() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "new")])
        try await services.emptyWorkspaces.populating(Self.key) { () async throws -> Void in }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        controller.applyCurrent()
        await Self.settle { false }
        #expect(recorder.keys.isEmpty)
        controller.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// A closing claim prevents creation. If the close is cancelled, an
    /// empty workspace can accept New again without an automatic terminal.
    @Test func workspaceEmptiedByATabDragIsNotRepaired() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "emptied")])
        services.emptyWorkspaces.beginClosing(Self.key)
        let workspace = try #require(services.daemon.store.workspaces.first)
        services.emptyWorkspaces.check(workspace) { _ in }
        services.emptyWorkspaces.createFirstTab(Self.key)
        await Self.settle { false }
        #expect(recorder.keys.isEmpty)
        services.emptyWorkspaces.endClosing(Self.key)
        services.emptyWorkspaces.check(workspace) { _ in }
        await Self.settle { false }
        #expect(recorder.keys.isEmpty, "a never-populated workspace still waits for New")
        services.emptyWorkspaces.createFirstTab(Self.key)
        await Self.settle { !recorder.keys.isEmpty }
        #expect(recorder.keys == [Self.key])
        withExtendedLifetime(services) {}
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

    @Test func failedExplicitCreationIsRetriedOnTheNextNewAction() async throws {
        let (services, recorder) = Self.services(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "empty")])
        struct Boom: Error {}
        services.emptyWorkspaces.create = { key in recorder.keys.append(key); throw Boom() }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        let actions = try #require(controller.emptyView)
        actions.onNew?()
        await Self.settle { recorder.keys.count == 1 }
        await Self.settle { false }
        controller.applyCurrent()
        await Self.settle { false }
        #expect(recorder.keys.count == 1, "a store change does not retry an explicit request")
        actions.onNew?()
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
