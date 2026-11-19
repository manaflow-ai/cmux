import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

// A visible move between machines (``ChatMoveDrop``): one-line forwards to the App's owners.
extension AppServices: ChatMoveHost {
    func chatMoveWorkspace(_ id: String) -> (workspace: WorkspaceModel, machine: String)? { machines.workspace(id: id).map { ($0.0, $0.1.machineID) } }
    func isChat(_ tab: AgentTabKey) -> Bool { agentTabs.record(for: tab) != nil }
    func chatMoveTargets(_ tab: AgentTabKey) -> [String] { agentTabs.machineTargets(tab).map(\.id) }
    func moveChat(_ tab: AgentTabKey, to machine: String) -> Bool { agentTabs.moveAgentToMachine(tab, machine) }
}
