import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// A chat's changes tab is a second tab on the chat's own session, so it read as the chat's title
/// ("Home" twice in the right split, claude-sr2 2026-10-22). It reads "Changes"; the chat keeps its title.
@MainActor
struct AgentChangesTabTitleTests {
    private static let host = "install:this-mac"

    @Test func theChangesTabIsTitledChangesAndTheChatKeepsItsTitle() throws {
        let session = "s-changes-\(UUID().uuidString)"
        let store = DaemonStore()
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "Home", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: session, harness: "claude"))
        var changes = chat
        changes.surface = 2
        let pane = PaneSnapshot(id: 1, tabs: [chat, changes])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: [:], showcase: true)
        tabs.localHost = Self.host
        let chatTab = try #require(store.tab(surface: 1))
        let changesTab = try #require(store.tab(surface: 2))
        let titles = TabTitleResolver(agentTabs: tabs)
        #expect(titles.title(changesTab) == "Home")

        let changes = AgentChangesPane.session(session)
        _ = changes.made(changesTab.id, opening: try #require(changes.begin("reveal")))
        #expect(titles.title(changesTab) == AgentPaneModel.changesTabTitle)
        #expect(titles.title(chatTab) == "Home")

        // Another tab leaving the chat leaves the record; the changes tab leaving it is an ordinary
        // chat from then on, even once it shows the chat again (Codex BLOCK at 32dffdca).
        AgentChangesPane.left(session) { tabs.resolve($0) == chatTab.id }
        #expect(titles.title(changesTab) == AgentPaneModel.changesTabTitle)
        AgentChangesPane.left(session) { tabs.resolve($0) == changesTab.id }
        #expect(titles.title(changesTab) == "Home")
    }

    /// A rejected opening ends early; its late callback must not end the opening that replaced it, or
    /// a third click opens a second pane (Codex BLOCK at bee4e65f).
    @Test func anOldOpeningsLateCallbackLeavesItsReplacementBeingMade() throws {
        let changes = AgentChangesPane.session("s-openings-\(UUID().uuidString)")
        let first = try #require(changes.begin("a"))
        changes.ended(first) // its tab moved to another chat before it was made
        let second = try #require(changes.begin("b"))
        changes.ended(first) // the first opening's finished callback
        #expect(changes.begin("c") == nil) // still being made: it shows c once it exists
        #expect(changes.made("k2", opening: second) == "c")
        #expect(changes.made("k1", opening: first) == nil)
    }
}
