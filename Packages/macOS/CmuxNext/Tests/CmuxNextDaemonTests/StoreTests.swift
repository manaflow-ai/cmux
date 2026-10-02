import Foundation
import Testing
@testable import CmuxNextDaemon

@MainActor @Suite struct StoreTests {
    private func loadedStore() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        return store
    }

    private func workspace(_ name: String, key: String, handle: UInt64) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: WorkspaceKey(rawValue: key), name: name)
    }

    @Test func snapshotBuildsModelsAndIndexes() throws {
        let store = try loadedStore()
        #expect(store.isLoaded)
        #expect(store.workspaces.map(\.name) == ["beta", "gamma"])
        #expect(store.workspaceRevision == 3)
        #expect(store.tab(surface: 3)?.displayTitle == "main")
        #expect(store.tab(surface: 3)?.hasUnread == true)
        #expect(store.pane(4)?.tabs.count == 2)
        #expect(store.screen(5)?.columns.count == 2)
        #expect(store.workspaces[0].unreadCount == 1)
        let terminal = try #require(store.tab(surface: 3)?.terminalID)
        #expect(store.tab(terminal: terminal)?.surface == 3)
    }

    @Test func resyncReusesModelsByDurableIdentityAcrossHandleChanges() throws {
        let store = try loadedStore()
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(store.tab(surface: 3))
        let pane = try #require(store.pane(4))

        // Same durable ids, new numeric handles (daemon restart).
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        tree.generation = "NEW"
        tree.workspaces[0].id = 101
        tree.workspaces[0].screens[0].panes[0].id = 404
        tree.workspaces[0].screens[0].panes[0].tabs[0].surface = 303
        tree.workspaces[0].screens[0].panes[0].tabs[0].title = "htop"
        store.apply(snapshot: tree)

        #expect(store.workspaces.first === workspace)
        #expect(store.tab(surface: 303) === tab)
        #expect(store.tab(surface: 3) == nil)
        #expect(tab.title == "htop")
        #expect(store.pane(404) === pane)
        #expect(workspace.handle == 101)
        #expect(store.generation == "NEW")
    }

    @Test func workspaceDeltasAreRevisionGated() throws {
        let store = try loadedStore()
        let generation = try #require(store.generation)

        // Already covered by the snapshot (revision 3): ignored.
        let stale = WorkspaceDelta(workspace: 14, index: 1, entity: workspace("gamma", key: "a0dc48bf-e02e-41c8-8440-73dc4c893c4a", handle: 14),
                                   workspaceRevision: 3, generation: generation)
        #expect(store.apply(.workspaceAdded(stale)) == .none)
        #expect(store.workspaces.count == 2)

        // Gap: 5 after 3 needs a resync and changes nothing.
        let gap = WorkspaceDelta(workspace: 20, index: 0, entity: workspace("far", key: "k-far", handle: 20),
                                 workspaceRevision: 5, generation: generation)
        #expect(store.apply(.workspaceAdded(gap)) == .resync)
        #expect(store.workspaces.count == 2)

        // Exact next revision applies at the given index.
        let next = WorkspaceDelta(workspace: 21, index: 0, entity: workspace("delta", key: "k-delta", handle: 21),
                                  workspaceRevision: 4, generation: generation)
        #expect(store.apply(.workspaceAdded(next)) == .none)
        #expect(store.workspaces.map(\.name) == ["delta", "beta", "gamma"])
        #expect(store.workspaceRevision == 4)
        #expect(store.workspace(handle: 21)?.name == "delta")

        // Move and close by durable key.
        let moved = WorkspaceDelta(workspace: 21, index: 2, entity: workspace("delta", key: "k-delta", handle: 21),
                                   workspaceRevision: 5, generation: generation)
        #expect(store.apply(.workspaceMoved(moved)) == .none)
        #expect(store.workspaces.map(\.name) == ["beta", "gamma", "delta"])
        let closed = WorkspaceDelta(workspace: 21, index: 2, entity: workspace("delta", key: "k-delta", handle: 21),
                                    workspaceRevision: 6, generation: generation)
        #expect(store.apply(.workspaceClosed(closed)) == .none)
        #expect(store.workspaces.map(\.name) == ["beta", "gamma"])

        // Another generation: resync.
        let foreign = WorkspaceDelta(workspace: 1, index: 0, entity: workspace("x", key: "k-x", handle: 1),
                                     workspaceRevision: 7, generation: "OTHER")
        #expect(store.apply(.workspaceAdded(foreign)) == .resync)
    }

    @Test func tabDeltasAreIdempotentAndSurfaceEventsUpdateInPlace() throws {
        let store = try loadedStore()
        let entity = TabSnapshot(surface: 50, tabResourceID: "tab_new", terminalID: "t50", title: "new")
        let delta = TabDelta(workspace: 1, screen: 5, pane: 7, surface: 50, index: 0, entity: entity)
        #expect(store.apply(.tabAdded(delta)) == .none)
        #expect(store.apply(.tabAdded(delta)) == .none)
        #expect(store.pane(7)?.tabs.map(\.surface) == [50, 6])

        store.apply(.titleChanged(surface: 50, title: "cargo test"))
        #expect(store.tab(surface: 50)?.title == "cargo test")
        store.apply(.surfaceResized(surface: 50, size: CellSize(cols: 120, rows: 40)))
        #expect(store.tab(surface: 50)?.size == CellSize(cols: 120, rows: 40))
        store.apply(.agentChanged(AgentStatus(surface: 50, state: .working, agent: "claude")))
        #expect(store.tab(surface: 50)?.agent?.state == .working)

        #expect(store.apply(.tabClosed(delta)) == .none)
        #expect(store.tab(surface: 50) == nil)
        #expect(store.pane(7)?.tabs.map(\.surface) == [6])

        // A delta for an unknown pane cannot apply exactly.
        let orphan = TabDelta(workspace: 1, screen: 5, pane: 999, surface: 51, index: 0, entity: TabSnapshot(surface: 51))
        #expect(store.apply(.tabAdded(orphan)) == .resync)
    }

    @Test func capturedEventStreamConvergesToFinalSnapshot() throws {
        // Replay the real stream against the initial tree, resyncing with the
        // final snapshot whenever the store asks, as `run(connection:)` does.
        let initial = try Fixture.response(DaemonTree.self, "list-workspaces-empty.json")
        let final = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let store = DaemonStore()
        store.apply(snapshot: initial)
        var resyncs = 0
        for line in try Fixture.lines("events.jsonl") {
            let event = DaemonEvent.decode(name: Fixture.eventName(line)!, line: line)
            if store.apply(event) == .resync {
                resyncs += 1
                store.apply(snapshot: final)
            }
        }
        #expect(resyncs > 0)
        #expect(store.workspaces.map(\.name) == ["beta", "gamma"])
        #expect(store.tab(surface: 3)?.name == "main")
        #expect(store.notifications.map(\.title) == ["Build"])
        #expect(store.connectionState == .disconnected("daemon shut down"))
    }

    @Test func connectAndLayoutEventsRequestResync() {
        let store = DaemonStore()
        let identity = DaemonIdentity(generation: "g")
        #expect(store.apply(.connected(identity, generationChanged: false)) == .resync)
        #expect(store.connectionState == .connected(identity))
        #expect(store.apply(.layoutChanged(screen: 1, transaction: nil)) == .resync)
        #expect(store.apply(.treeChanged(transaction: nil)) == .resync)
        #expect(store.apply(.overflow("slow")) == .resync)
        #expect(store.apply(.bell(surface: 1)) == .none)
    }

    @Test func echoedTransactionIDsAreExposedOnce() throws {
        let store = try loadedStore()
        var confirmed: [ClientTransactionID] = []
        store.onTransactionConfirmed = { confirmed.append($0) }
        let entity = TabSnapshot(surface: 60, tabResourceID: "tab_moved")
        let delta = TabDelta(workspace: 1, screen: 5, pane: 7, surface: 60, index: 0, entity: entity, clientTransactionID: "tx-1")
        store.apply(.tabChanged(delta))
        store.apply(.layoutChanged(screen: 5, transaction: "tx-1"))
        store.apply(.treeChanged(transaction: "tx-2"))
        #expect(store.confirmedTransactions == ["tx-1", "tx-2"])
        #expect(confirmed == ["tx-1", "tx-2"])

        let line = Data(#"{"event":"tab-changed","workspace":1,"screen":5,"pane":7,"surface":6,"index":0,"entity":{"surface":6},"transaction":"tx-3"}"#.utf8)
        #expect(DaemonEvent.decode(name: "tab-changed", line: line).clientTransactionID == "tx-3")
    }

    @Test func metadataDeltasUpdateWorkspaceAndTab() throws {
        let store = try loadedStore()
        let generation = try #require(store.generation)
        var entity = WorkspaceSnapshot(id: 1, key: "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1", name: "beta")
        entity.screens = try Fixture.response(DaemonTree.self, "list-workspaces.json").workspaces[0].screens
        entity.color = "gray"
        entity.title = "Backend"
        entity.group = "agents"
        let delta = WorkspaceDelta(workspace: 1, index: 0, entity: entity, workspaceRevision: 4, generation: generation)
        #expect(store.apply(.workspaceChanged(delta)) == .none)
        let workspace = try #require(store.workspace(key: "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1"))
        #expect(workspace.displayName == "Backend")
        #expect(workspace.group == "agents")
        #expect(store.workspaceRevision == 4)

        var tab = try #require(store.tab(surface: 3)).snapshot
        tab.pinned = true
        tab.cwd = "/repo"
        tab.gitBranch = "main"
        #expect(store.apply(.tabChanged(TabDelta(workspace: 1, screen: 5, pane: 4, surface: 3, index: 0, entity: tab))) == .none)
        #expect(store.tab(surface: 3)?.pinned == true)
        #expect(store.tab(surface: 3)?.gitBranch == "main")
    }

    /// Regression: Ghostty's zsh integration reports `kitty-shell-cwd://` URLs, which
    /// the pinned daemon reads as no directory, so it clears the tab's cwd at the
    /// first prompt. The folder the shell reported to this app's own surface keeps
    /// the tab's cwd, so ⌘T and the new tab page start in it; a daemon cwd wins.
    @Test func theShellsReportedFolderKeepsTheTabCwdWhenTheDaemonClearsIt() throws {
        let store = try loadedStore()
        var tab = try #require(store.tab(surface: 3)).snapshot
        tab.cwd = nil
        let cleared = TabDelta(workspace: 1, screen: 5, pane: 4, surface: 3, index: 0, entity: tab)
        _ = store.apply(.tabChanged(cleared))
        store.noteTerminalDirectory("/Users/me/code/web-app", surface: 3)
        #expect(store.tab(surface: 3)?.cwd == "/Users/me/code/web-app")
        _ = store.apply(.tabChanged(cleared))
        #expect(store.tab(surface: 3)?.cwd == "/Users/me/code/web-app")
        store.noteTerminalDirectory("file://host/Users/me/code/api%20server", surface: 3)
        #expect(store.tab(surface: 3)?.cwd == "/Users/me/code/api server")
        store.noteTerminalDirectory("kitty-shell-cwd://host/Users/me/100% done", surface: 3)
        #expect(store.tab(surface: 3)?.cwd == "/Users/me/100% done")

        // A relative or `~` report is not a folder to start in.
        store.noteTerminalDirectory("~/code", surface: 3)
        #expect(store.tab(surface: 3)?.cwd == nil)
        store.noteTerminalDirectory("/Users/me/code/web-app", surface: 3)

        // A resync rebuilds the tab; the folder stays with its surface.
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        _ = store.apply(.tabChanged(cleared))
        #expect(store.tab(surface: 3)?.cwd == "/Users/me/code/web-app")

        tab.cwd = "/srv"
        _ = store.apply(.tabChanged(TabDelta(workspace: 1, screen: 5, pane: 4, surface: 3, index: 0, entity: tab)))
        #expect(store.tab(surface: 3)?.cwd == "/srv")
    }

    /// A remote terminal's shell reports a folder on another machine.
    @Test func aRemoteTerminalsReportedFolderIsNotALocalCwd() throws {
        let store = try loadedStore()
        var tab = try #require(store.tab(surface: 3)).snapshot
        tab.kind = .remoteTerminal
        tab.cwd = nil
        _ = store.apply(.tabChanged(TabDelta(workspace: 1, screen: 5, pane: 4, surface: 3, index: 0, entity: tab)))
        store.noteTerminalDirectory("/home/dev/api", surface: 3)
        #expect(store.tab(surface: 3)?.cwd == nil)
    }
}
