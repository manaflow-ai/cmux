import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A workspace that is empty only for a moment shows nothing, not its
/// new-workspace actions. Cmd-N creates the workspace, then its first
/// terminal: between the two the window showed "Start something new" with
/// no tab strip for one frame, then the strip and the terminal popped in.
/// A workspace whose last tab closed flashed the same actions before it
/// closed. A genuinely new empty workspace keeps its actions.
@MainActor
struct EmptyWorkspaceSettlingTests {
    private static let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02")

    private static func emptied(_ revision: UInt64) -> DaemonTree {
        DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "w")])
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// The actions are shown (the empty view is mounted and the layout hidden).
    private static func showsActions(_ controller: WorkspaceContentController) -> Bool {
        controller.contentView.emptyView != nil && controller.contentView.emptyView === controller.emptyView
    }

    @Test func workspaceThisAppIsPopulatingShowsNoActions() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.emptyWorkspaces.canCreate = { true }
        services.daemon.store.apply(snapshot: Self.emptied(1))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { controller.teardown() }
        #expect(Self.showsActions(controller), "a new empty workspace offers its actions")

        // Cmd-N: create-workspace answered, create-terminal still in flight.
        var release: CheckedContinuation<Void, Never>?
        let populate = Task { @MainActor in
            await services.emptyWorkspaces.populating(Self.key) {
                await withCheckedContinuation { release = $0 }
            }
        }
        await Self.settle { release != nil }
        await Self.settle { !Self.showsActions(controller) }
        #expect(!Self.showsActions(controller), "the first terminal is on its way")

        // create-terminal answered; the pane delta has not reached the mirror.
        release?.resume()
        await populate.value
        controller.applyCurrent()
        await Self.settle { false }
        #expect(!Self.showsActions(controller), "the pane is on its way")
        withExtendedLifetime((services, state)) {}
    }

    @Test func workspaceWhoseLastTabClosedShowsNoActionsWhileItCloses() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.cause = { _ in .tabClosed }
        var closes: [WorkspaceKey] = []
        services.emptyWorkspaces.close = { key in closes.append(key) }
        let workspace = try #require(services.daemon.store.workspaces.first { $0.key == Self.key })
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { controller.teardown() }
        await Self.settle { false }

        services.daemon.store.apply(snapshot: Self.emptied(2))
        controller.applyCurrent()
        await Self.settle { !closes.isEmpty }
        #expect(closes == [Self.key])
        #expect(!Self.showsActions(controller), "it is closing, not waiting for the user")
        withExtendedLifetime((services, state)) {}
    }

    @Test func failedNewTabBringsTheActionsBack() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        struct Boom: Error {}
        var release: CheckedContinuation<Void, Never>?
        services.emptyWorkspaces.canCreate = { true }
        services.emptyWorkspaces.create = { _ in
            await withCheckedContinuation { release = $0 }
            throw Boom()
        }
        services.daemon.store.apply(snapshot: Self.emptied(1))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { controller.teardown() }
        services.emptyWorkspaces.createFirst = nil

        controller.emptyView?.onNew?()
        await Self.settle { release != nil }
        await Self.settle { !Self.showsActions(controller) }
        #expect(!Self.showsActions(controller), "New was pressed; the tab is on its way")

        release?.resume()
        await Self.settle { Self.showsActions(controller) }
        #expect(Self.showsActions(controller), "the create failed: the user can try again")
        withExtendedLifetime((services, state)) {}
    }
}
