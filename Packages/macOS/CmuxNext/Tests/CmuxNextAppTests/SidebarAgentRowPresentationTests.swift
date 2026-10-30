import Foundation
@testable import CmuxNextDaemon
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextSidebar

/// Agent rows prefer a readable chat title and never manufacture a raw prompt subtitle.
struct SidebarAgentRowPresentationTests {
    @Test func aNamedChatTitleWinsOverItsSessionName() {
        let named: [String: Any] = ["sessionId": "lane-1", "name": "lane-1", "title": "Review the release", "titleSource": "generated"]
        #expect(AgentTurnStates.title(named, includingPrompt: false) == "Review the release")
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
    }

    @Test func aPromptWithoutAReadableTitleIsNotAStableTitle() {
        let promptOnly: [String: Any] = ["sessionId": "lane-1", "name": "lane-1", "lastPrompt": "Implement the adapter"]
        #expect(AgentTurnStates.title(promptOnly, includingPrompt: false) == nil)
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: nil, taskSummary: "Implement the adapter") == "Implement the adapter")
    }

    @Test func aRestoredLegacyWorkspaceUsesItsSessionIdentity() {
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "demo-lane", workspaceName: "demo-lane",
                                             workspaceNameSource: .user, workspaceNameRevision: 0,
                                             sessionName: "demo-lane", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
    }

    @Test func aRenamedAgentWorkspaceKeepsTheUserName() {
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "My review", sessionName: "lane-1",
                                             chatTitle: "Review the release", taskSummary: "Implement the adapter") == "My review")
    }

    @MainActor
    @Test func anExplicitWorkspaceTitleAlwaysWins() throws {
        let workspace = try fixture(nameSource: .auto, title: "  My review  ")
        #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: true).title == "  My review  ")
    }

    @MainActor
    @Test func aNamedChatTitleAlwaysWins() throws {
        let workspace = try fixture(nameSource: .auto)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        for name in ["  My chat  ", "demo-lane"] {
            tab.name = name
            #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: true).title == name)
        }
    }

    @MainActor
    @Test func aRenameToADefaultLookingNameStillWins() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .user, nameRevision: 2)
        #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: true).title == "workspace-7")
    }

    @MainActor
    @Test func disabledAutomaticNamingKeepsTheDefault() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .auto)
        #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: false).title == "workspace-7")
        #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: true).title == "Review the release")
    }

    @MainActor
    @Test func aFreeFormPromptDoesNotBecomeTheRowTitle() throws {
        let workspace = try fixture(nameSource: .auto, freeFormPrompt: true)
        #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: true).title == "demo-lane")
    }

    @MainActor
    @Test func aRunningTerminalFrontDoesNotUseABackgroundChatTitle() throws {
        let workspace = try fixture(nameSource: .auto, terminalFront: true)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        let terminal = try #require(tabs.first(where: { $0.agentSession == nil }))
        #expect(SidebarMapping.shared.row(workspace, machine: .local, selectedTab: { _ in terminal.id },
                                         autoNamesWorkspaces: true).title == "demo-lane")
    }

    @MainActor
    @Test func theFrontChatUsesItsOwnTask() throws {
        let workspace = try fixture(nameSource: .auto, secondAgent: true)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        #expect(SidebarMapping.shared.agentTab(tabs)?.id == tabs[1].id)
        #expect(SidebarMapping.shared.row(workspace, machine: .local, selectedTab: { _ in tabs[0].id },
                                         autoNamesWorkspaces: true).title == "Review the release")
        #expect(SidebarMapping.shared.row(workspace, machine: .local, selectedTab: { _ in tabs[1].id },
                                         autoNamesWorkspaces: true).title == "Fix the other task")
    }

    @MainActor
    @Test func anUnbrandedHarnessStillGetsAReadableTaskTitle() throws {
        let workspace = try fixture()
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        #expect(tab.agentBrand == nil)
        #expect(SidebarMapping.shared.row(workspace, machine: .local, autoNamesWorkspaces: true).title == "Review the release")
    }

    @MainActor
    private func fixture(name: String = "demo-lane", nameSource: WorkspaceNameSource = .user,
                         nameRevision: UInt64 = 0, title: String? = nil, secondAgent: Bool = false,
                         terminalFront: Bool = false, freeFormPrompt: Bool = false) throws -> WorkspaceModel {
        var chat = TabSnapshot(surface: 1, kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(
            host: "install:sidebar-title-fixture", session: "demo-lane", harness: "custom-fixture-harness"))
        var chats = [chat]
        if terminalFront {
            var terminal = TabSnapshot(surface: 99, kind: .pty, cwd: "/tmp")
            terminal.title = "npm run dev"
            terminal.commandSinceMs = 1
            chats.insert(terminal, at: 0)
        }
        if secondAgent {
            var other = TabSnapshot(surface: 2, kind: .conversation, cwd: nil)
            other.conversation = ConversationTabRef(agentSession: AgentSessionRef(
                host: "install:sidebar-title-fixture", session: "demo-other", harness: "claude"))
            chats.append(other)
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: chats)])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: name, nameSource: nameSource, nameRevision: nameRevision,
                              screens: [screen], title: title)
        ]))
        let workspace = try #require(store.workspaces.first)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        let firstChat = try #require(tabs.first(where: { $0.agentSession != nil }))
        firstChat.agent = AgentStatus(surface: 1, state: .idle, agent: "custom-fixture-harness",
                                   lastPrompt: freeFormPrompt ? "Implement the adapter and report the result." : "Your task:\nTitle: Review the release\nCheck the build and report failures.")
        if secondAgent {
            let secondChat = try #require(tabs.last(where: { $0.agentSession != nil }))
            secondChat.agent = AgentStatus(surface: 2, state: .working, agent: "claude",
                                       lastPrompt: "Your task:\nTitle: Fix the other task\nCheck a separate project.")
        }
        return workspace
    }

    @Test func statusAndRepositoryFactsRemainSeparateFromTitle() {
        let row = SidebarWorkspace(id: WorkspaceID("row"), title: "Review the release", directory: "~/work/repo", branch: "main", status: "Waiting")
        let content = WorkspaceRowContent(row, preferences: .defaults)
        #expect(content.detail == nil || content.detail?.contains("Implement") == false)
    }
}
