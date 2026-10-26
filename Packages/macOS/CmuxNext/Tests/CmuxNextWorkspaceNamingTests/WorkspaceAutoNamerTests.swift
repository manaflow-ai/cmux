@testable import CmuxNextDaemon
import CmuxNextWorkspaceNaming
import Testing

/// Workspace auto-naming follows the focused agent chat while the daemon still
/// marks the workspace as automatic; a user-owned workspace and stale queued
/// observations remain fenced.
@MainActor
struct WorkspaceAutoNamerTests {
    private static let host = "install:auto-name-namer"

    private static func reader(_ turns: AgentTurnStateStore) -> WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(
            enabled: { true },
            isNewTabPage: { _ in false },
            livePage: { _ in nil },
            incognitoTitle: { _ in nil },
            terminal: { tab in .init(kind: .terminal, userName: nil, title: tab.titleText, pageTitle: nil, url: nil, cwd: tab.cwd) },
            turns: turns,
            hold: WorkspaceAutoNameHold())
    }

    private static func chat(surface: UInt64, session: String) -> TabSnapshot {
        var tab = TabSnapshot(surface: surface, kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        return tab
    }

    private static func workspace(name: String, source: WorkspaceNameSource = .auto, revision: UInt64 = 1,
                                 tabs: [TabSnapshot]) throws -> WorkspaceModel {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: tabs)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "auto-name-test"),
                                                                         name: name, nameSource: source,
                                                                         nameRevision: revision, screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    private static func setTitle(_ turns: AgentTurnStateStore, session: String, title: String) {
        turns.localHost = host
        turns.apply(session: session, state: nil, lastMessage: nil, muted: false,
                    title: title, generatedTitle: title, detail: nil)
    }

    private final class RenameRecorder {
        var names: [String] = []
    }

    private static func namer(_ turns: AgentTurnStateStore, workspace: WorkspaceModel,
                              recorder: RenameRecorder) -> WorkspaceAutoNamer {
        let names = reader(turns)
        return WorkspaceAutoNamer(
            names: names,
            workspaces: { [workspace] in
                [WorkspaceAutoNamer.Target(machineID: DaemonCommandScope.localMachine, workspace: workspace,
                                           supportsNameSource: true, daemonGeneration: nil,
                                           nameSource: workspace.nameSource, nameRevision: workspace.nameRevision)]
            },
            selection: { _, _ in nil },
            rename: { _, name in recorder.names.append(name) })
    }

    @Test func anAutomaticWorkspaceFollowsASecondGeneratedTitle() throws {
        let turns = AgentTurnStateStore()
        let workspace = try Self.workspace(name: "First title", tabs: [Self.chat(surface: 1, session: "s1")])
        Self.setTitle(turns, session: "s1", title: "Second title")
        let recorder = RenameRecorder()
        let namer = Self.namer(turns, workspace: workspace, recorder: recorder)

        let first = namer.pending()
        #expect(first.count == 1)
        #expect(first.first?.name == "Second title")
        namer.apply(first)
        #expect(recorder.names == ["Second title"])

        workspace.update(WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "auto-name-test"),
                                           name: "Second title", nameSource: .auto, nameRevision: 2,
                                           screens: workspace.screens.map { _ in
                                               ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [Self.chat(surface: 1, session: "s1")])])
                                           }))
        Self.setTitle(turns, session: "s1", title: "Third title")
        let second = namer.pending()
        #expect(second.first?.name == "Third title")
        namer.apply(second)
        #expect(recorder.names == ["Second title", "Third title"])
    }

    @Test func aQueuedRenameIsDroppedWhenTheFocusedChatChanges() throws {
        let turns = AgentTurnStateStore()
        let workspace = try Self.workspace(name: "Old title", tabs: [Self.chat(surface: 1, session: "s1"), Self.chat(surface: 2, session: "s2")])
        Self.setTitle(turns, session: "s1", title: "Chat one")
        Self.setTitle(turns, session: "s2", title: "Chat two")
        let recorder = RenameRecorder()
        let namer = Self.namer(turns, workspace: workspace, recorder: recorder)
        let queued = namer.pending()
        #expect(queued.first?.name == "Chat one")

        workspace.update(WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "auto-name-test"),
                                           name: "Old title", nameSource: .auto, nameRevision: 1,
                                           screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, activeTab: 1, tabs: [Self.chat(surface: 1, session: "s1"), Self.chat(surface: 2, session: "s2")])])]))
        namer.apply(queued)
        #expect(recorder.names.isEmpty)
    }

    @Test func aQueuedRenameIsDroppedWhenTheChatTitleChanges() throws {
        let turns = AgentTurnStateStore()
        let workspace = try Self.workspace(name: "Old title", tabs: [Self.chat(surface: 1, session: "s1")])
        Self.setTitle(turns, session: "s1", title: "Chat one")
        let recorder = RenameRecorder()
        let namer = Self.namer(turns, workspace: workspace, recorder: recorder)
        let queued = namer.pending()
        Self.setTitle(turns, session: "s1", title: "Chat one updated")
        namer.apply(queued)
        #expect(recorder.names.isEmpty)
    }

    @Test func aQueuedRenameIsDroppedAfterAUserRename() throws {
        let turns = AgentTurnStateStore()
        let workspace = try Self.workspace(name: "Old title", tabs: [Self.chat(surface: 1, session: "s1")])
        Self.setTitle(turns, session: "s1", title: "Chat one")
        let recorder = RenameRecorder()
        let namer = Self.namer(turns, workspace: workspace, recorder: recorder)
        let queued = namer.pending()

        workspace.update(WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "auto-name-test"),
                                           name: "Mine", nameSource: .user, nameRevision: 3,
                                           screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [Self.chat(surface: 1, session: "s1")])])]))
        namer.apply(queued)
        #expect(recorder.names.isEmpty)
    }
}
