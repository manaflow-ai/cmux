import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Another machine's running chat opened here (`agent-session-adopt`) keeps its mode; one that acts
/// without asking (bypass) puts a warning on its workspace's row, first in the status block, and
/// no row setting hides it (policy (b): adopt bypass chats only on enrolled hosts, nothing hidden).
@MainActor @Suite(.serialized)
struct AgentBypassBadgeTests {
    /// A workspace whose one pane holds a terminal and the agent tab of `session` on huge-blue.
    static func workspace(session: String) throws -> WorkspaceModel {
        var chat = TabSnapshot(surface: 2, kind: .conversation, title: "lane", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:huge-blue", hostName: "huge-blue", session: session))
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1"), chat])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "lane",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        return try #require(store.workspaces.first)
    }

    @Test func aBypassChatWarnsOnItsRowWhateverTheRowShows() throws {
        let bypassed = try Self.workspace(session: "bypass-1")
        AgentBypassSessions.shared.set("bypass-1", bypass: true)
        defer { AgentBypassSessions.shared.set("bypass-1", bypass: false) }
        let row = SidebarMapping.shared.row(bypassed, machine: CmuxNextSidebar.MachineID("huge-blue"))
        #expect(row.reported?.entries.first?.key == SidebarWorkspaceStatus.Entry.bypassKey, "the row carries no bypass warning")

        // The person's quietest row (no agent status element) and the expanded row still say it.
        let text = SidebarWorkspaceStatus.Entry.bypass.text
        let minimal = WorkspaceRowContent(row, preferences: WorkspaceRowPreferences(base: .minimal))
        #expect(minimal.status?.entries.first?.key == SidebarWorkspaceStatus.Entry.bypassKey || minimal.trailingStatus == text,
                "a row without the agent status element hides the bypass warning")
        let expanded = WorkspaceRowContent(expanded: row, now: Date())
        #expect(expanded.meta?.contains(text) == true, "the expanded row hides the bypass warning")

        // A chat that asks has no warning.
        let asking = SidebarMapping.shared.row(try Self.workspace(session: "ask-1"), machine: CmuxNextSidebar.MachineID("huge-blue"))
        #expect(asking.reported?.entries.contains { $0.key == SidebarWorkspaceStatus.Entry.bypassKey } != true)
    }
}
