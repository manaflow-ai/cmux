import Testing
@testable import CmuxNextDaemon

/// A tab keeps what it is when it moves (Leo 2026-10-19: "new tab becomes about blank when i drag
/// it from an existing workspace to its own workspace"). The daemon moves the same tab, and the
/// store shows it in its new pane with the same id and the same descriptor: a New Tab page stays
/// a blank agent chat (never a browser at about:blank), a chat keeps its session, a Home tab its
/// conversation, a page tab its page and route, a browser its address, engine, profile and pin,
/// a terminal its terminal. The app's views and pages are keyed by that id, so they follow it.
/// These pass at the base too: they pin down that the move keeps the tab, so a regression there
/// shows here. The "about:blank" Leo saw was the new workspace's name (`MovedTabWorkspaceNameTests`).
@MainActor
struct TabMoveKeepsDescriptorTests {
    struct Kind: CustomTestStringConvertible, Sendable {
        let name: String
        let tab: @Sendable () -> TabSnapshot
        var testDescription: String { name }
    }

    nonisolated static let kinds: [Kind] = [
        Kind(name: "New Tab page") {
            var tab = TabSnapshot(surface: 7, kind: .conversation, title: "about:blank")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:mac", harness: "claude"))
            return tab
        },
        Kind(name: "agent chat") {
            var tab = TabSnapshot(surface: 7, kind: .conversation, name: "Release notes", title: "about:blank")
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:mac", session: "s-1", harness: "codex"))
            return tab
        },
        Kind(name: "Chief / Home conversation") {
            var tab = TabSnapshot(surface: 7, kind: .conversation, title: "about:blank")
            tab.conversation = ConversationTabRef(conversation: "chief-main", owner: "home")
            return tab
        },
        Kind(name: "page tab (Settings, file viewer)") {
            var tab = TabSnapshot(surface: 7, kind: .conversation, title: "about:blank")
            tab.conversation = ConversationTabRef(page: "files", route: "/Users/me/notes/README.md")
            return tab
        },
        Kind(name: "pinned browser page") {
            var tab = TabSnapshot(surface: 7, kind: .browser, title: "Pull requests", url: "https://github.com/pulls", pinned: true,
                                  browserRenderer: "frontend", browserEngine: "chromium", browserProfileID: "work")
            tab.pinnedURL = "https://github.com"
            return tab
        },
        Kind(name: "app tab") {
            var tab = TabSnapshot(surface: 7, kind: .browser, title: "about:blank", url: "about:blank", browserRenderer: "frontend")
            tab.app = AppTabRef(app: "coderouter", route: "/runs")
            return tab
        },
        Kind(name: "terminal") {
            TabSnapshot(surface: 7, terminalID: "70", terminalIncarnation: "3", kind: .pty, title: "vim notes.md", cwd: "/Users/me/notes")
        },
    ]

    /// Workspace 1 holds the moved tab (surface 7) beside a terminal (surface 1) in pane 10, and
    /// pane 11 beside it holds another terminal (surface 2).
    private func store(with moved: TabSnapshot) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 10, tabs: [TabSnapshot(surface: 1), moved])
        let other = PaneSnapshot(id: 11, tabs: [TabSnapshot(surface: 2)])
        let screen = ScreenSnapshot(id: 100, layout: .leaf(10), panes: [pane, other])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1,
                                         workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        return store
    }

    /// What the descriptor is, apart from where it sits.
    private func descriptor(_ tab: TabModel?) -> [String] {
        guard let tab else { return ["missing"] }
        return [tab.id, "\(tab.kind)", tab.name ?? "-", tab.url ?? "-", "\(tab.pinned)", tab.pinnedURL ?? "-", tab.browserEngine ?? "-",
                tab.browserProfileID ?? "-", "\(tab.isFrontendOwned)", tab.cwd ?? "-", "\(String(describing: tab.terminalID))",
                "\(String(describing: tab.terminalIncarnation))", "\(String(describing: tab.conversation))", "\(String(describing: tab.app))",
                "\(String(describing: tab.agentSession))", tab.page ?? "-", tab.pageRoute ?? "-"]
    }

    private func listed(_ id: String, in store: DaemonStore) -> Int {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.id == id }.count
    }

    /// Drag to the sidebar, tear-off, Move Tab to New Workspace / New Window (`move-tab-to-new-workspace`):
    /// the new workspace's added delta carries the tab, then its tab-changed names the new pane.
    @Test(arguments: kinds)
    func aTabMovedToANewWorkspaceKeepsItsDescriptor(_ kind: Kind) {
        let store = store(with: kind.tab())
        let before = descriptor(store.tab(surface: 7))
        let pane = PaneSnapshot(id: 20, tabs: [kind.tab()])
        let screen = ScreenSnapshot(id: 200, layout: .leaf(20), panes: [pane])
        let created = WorkspaceSnapshot(id: 2, key: nil, name: "workspace-2", screens: [screen])
        #expect(store.apply(.workspaceAdded(WorkspaceDelta(workspace: 2, index: 1, entity: created, workspaceRevision: 2))) == DaemonStore.Followup.none)
        #expect(store.apply(.tabChanged(TabDelta(workspace: 2, screen: 200, pane: 20, surface: 7, index: 0, entity: kind.tab()))) == DaemonStore.Followup.none)

        #expect(descriptor(store.tab(surface: 7)) == before)
        #expect(listed(before[0], in: store) == 1)
        #expect(store.pane(containing: 7)?.handle == 20)
        #expect(store.workspace(containing: 20)?.handle == 2)
    }

    /// Drag onto another pane's strip or a new split, Move Tab to Pane (`move-tab`, `move-tab-to-split`).
    @Test(arguments: kinds)
    func aTabMovedToAnotherPaneKeepsItsDescriptorAndRecord(_ kind: Kind) {
        let store = store(with: kind.tab())
        let record = store.tab(surface: 7)
        let before = descriptor(record)
        #expect(store.apply(.tabChanged(TabDelta(workspace: 1, screen: 100, pane: 11, surface: 7, index: 1, entity: kind.tab()))) == DaemonStore.Followup.none)

        #expect(descriptor(store.tab(surface: 7)) == before)
        #expect(store.tab(surface: 7) === record)
        #expect(listed(before[0], in: store) == 1)
        #expect(store.pane(containing: 7)?.handle == 11)
    }

    /// Drag onto another workspace's sidebar row, Move Tab to Workspace (`move-tab-to-workspace`).
    @Test(arguments: kinds)
    func aTabMovedToAnotherWorkspaceKeepsItsDescriptor(_ kind: Kind) {
        let store = store(with: kind.tab())
        let before = descriptor(store.tab(surface: 7))
        let pane = PaneSnapshot(id: 30, tabs: [TabSnapshot(surface: 3)])
        let screen = ScreenSnapshot(id: 300, layout: .leaf(30), panes: [pane])
        let target = WorkspaceSnapshot(id: 3, key: nil, name: "workspace-3", screens: [screen])
        #expect(store.apply(.workspaceAdded(WorkspaceDelta(workspace: 3, index: 1, entity: target, workspaceRevision: 2))) == DaemonStore.Followup.none)
        #expect(store.apply(.tabChanged(TabDelta(workspace: 3, screen: 300, pane: 30, surface: 7, index: 1, entity: kind.tab()))) == DaemonStore.Followup.none)

        #expect(descriptor(store.tab(surface: 7)) == before)
        #expect(listed(before[0], in: store) == 1)
        #expect(store.workspace(containing: 30)?.handle == 3)
        #expect(store.pane(containing: 7)?.handle == 30)
    }
}
