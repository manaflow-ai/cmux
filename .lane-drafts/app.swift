// ---- CmuxNextApp/SidebarBridge+Subagents.swift
import CmuxNextSidebar
import Foundation

extension SidebarBridge {
    /// A subagent's line under a chat row (`SidebarIntent.openSubagent`): shows the chat's tab, then opens
    /// the subagent's pane beside it the way the chat's own subagent cards do (`chat.subagentPane`,
    /// ``AgentTabStore/openSubagentFromSidebar``). No subagent ("N more", the stacked line): the chat only.
    func openSubagent(_ agent: String?, title: String?, chatTab tab: TabID) {
        revealPinnedTab(tab.rawValue)
        guard let agent, let (model, _) = pinnedTab(tab.rawValue) else { return }
        services.agentTabs.openSubagentFromSidebar(agent, title: title, chat: model)
    }
}

// ---- AgentTabs+Header.swift addition
    /// The sidebar's subagent line: opens `agent`'s pane beside chat tab `chat` with focus, through the tracker the
    /// chat's subagent cards use (``openSubagent(_:of:focus:asked:beside:machine:)``). False when the tab shows no session.
    @discardableResult
    func openSubagentFromSidebar(_ agent: String, title: String?, chat tab: TabModel) -> Bool {
        let key = tabKey(of: tab)
        guard let session = session(of: key.key, machine: key.machine) ?? tab.agentSession?.session else { return false }
        SubagentTabTitles.shared.name(agent, of: session, title: title, tone: nil, mark: nil)
        return openSubagent(agent, of: session, focus: true, beside: key.key, machine: key.machine.isEmpty ? nil : key.machine)
    }
