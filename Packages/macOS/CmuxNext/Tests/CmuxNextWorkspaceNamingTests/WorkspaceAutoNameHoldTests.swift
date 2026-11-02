import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWorkspaceNaming
import Testing

/// A sidebar row named by its front chat keeps that name while the chat's
/// title is briefly unknown (the title store between a relaunch or watch
/// reconnect and its first page, a tree resync): it never drops back to the
/// daemon's `workspace-N` in the meantime. A user's name still wins, and
/// another front tab names the row afresh.
@MainActor
struct WorkspaceAutoNameHoldTests {
    private static let host = "install:hold-test"

    /// A default-named workspace whose one pane shows chat `session`, with a terminal and a page beside it.
    private static func workspace(_ store: DaemonStore, name: String = "workspace-7", session: String?) throws -> WorkspaceModel {
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        let terminal = TabSnapshot(surface: 2, kind: .pty, title: "zsh", cwd: "/tmp/api")
        let page = TabSnapshot(surface: 3, kind: .browser, title: "Pull request", url: "https://github.com/manaflow-ai/cmux/pull/1")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, terminal, page])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: name, screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    private static func reader(_ turns: AgentTurnStateStore) -> WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(enabled: { true }, isNewTabPage: { _ in false }, livePage: { _ in nil }, incognitoTitle: { _ in nil },
                                terminal: { tab in .init(kind: .terminal, userName: nil, title: tab.titleText, pageTitle: nil, url: nil, cwd: tab.cwd) },
                                turns: turns, hold: WorkspaceAutoNameHold())
    }

    private static func title(_ turns: AgentTurnStateStore, _ session: String, _ title: String?) {
        turns.apply(session: session, state: nil, lastMessage: nil, muted: false, title: title, generatedTitle: title, detail: nil)
    }

    @Test func aChatNamedRowKeepsItsNameWhileTheTitleIsUnknown() throws {
        let session = "hold-\(#line)"
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        let workspace = try Self.workspace(DaemonStore(), session: session)
        let chat = try #require(workspace.screens.first?.panes.first?.tabs.first)
        let reader = Self.reader(turns)

        Self.title(turns, session, "Hide sub-session agents")
        #expect(reader.label(workspace, front: chat, work: nil) == "Hide sub-session agents")
        // The tab list maps each page's face too (`SidebarMapping.row`); that does not take the chat's hold.
        let page = try #require(workspace.screens.first?.panes.first?.tabs.last)
        #expect(reader.label(workspace, front: page, work: nil) == "Pull request")

        Self.title(turns, session, nil)
        #expect(reader.label(workspace, front: chat, work: nil) == "Hide sub-session agents")

        Self.title(turns, session, "Hide sub-session agents in sidebar")
        #expect(reader.label(workspace, front: chat, work: nil) == "Hide sub-session agents in sidebar")
    }

    @Test func anotherFrontTabOrTheUsersNameIsNotHeldOver() throws {
        let session = "hold-\(#line)"
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        let store = DaemonStore()
        let workspace = try Self.workspace(store, session: session)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        let reader = Self.reader(turns)

        Self.title(turns, session, "Fix the login bug")
        #expect(reader.label(workspace, front: tabs[0], work: nil) == "Fix the login bug")
        // The terminal names the row itself; the chat's name is not carried over to it.
        #expect(reader.label(workspace, front: tabs[1], work: nil) == "api")

        // A new chat in the same tab (or its New Tab page) starts unnamed, not with the old chat's name.
        Self.title(turns, session, nil)
        let fresh = try Self.workspace(store, session: nil)
        #expect(reader.label(fresh, front: tabs[0], work: nil) == nil)

        let renamed = try Self.workspace(store, name: "Release", session: session)
        #expect(reader.label(renamed, front: tabs[0], work: nil) == nil)
    }
}
