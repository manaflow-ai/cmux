import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

extension AppServices: ChatMoveHost {
    func chatMoveWorkspace(_ id: String) -> WorkspaceModel? { machines.workspace(id: id)?.0 }
    func chatMoveMachine(ofWorkspace id: String) -> String? { machines.workspace(id: id)?.1.machineID }
    func isChat(_ tab: AgentTabKey) -> Bool { agentTabs.record(for: tab) != nil }
    func chatMoveTargets(_ tab: AgentTabKey) -> [String] { agentTabs.machineTargets(tab).map(\.id) }
    func moveChat(_ tab: AgentTabKey, to machine: String) -> Bool { agentTabs.moveAgentToMachine(tab, machine) }
}
