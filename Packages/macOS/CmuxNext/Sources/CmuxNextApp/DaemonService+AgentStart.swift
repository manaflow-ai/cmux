import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// The store's answer for where a new agent chat of `workspace` starts
    /// (`workspace.agent_start.get`, cx-9aps). Nil from a daemon without `workspace-agent-start-v1`
    /// or when the read fails, so the pane keeps its own rules (compatibility only, cx-6bf9).
    func agentStart(_ cwd: String?, workspace: ResourceID) async -> AgentPaneStartFolder? {
        guard supports(DaemonCapabilities.shared.workspaceAgentStart), let connection else { return nil }
        do {
            let answer = try await connection.state.agentStart(workspace, cwd: cwd)
            return AgentPaneStartFolder(kind: answer.kind, cwd: answer.cwd, agentHome: answer.agentHome,
                                        skipped: answer.skipped.map { ($0.cwd, $0.reason) })
        } catch {
            logger.error("workspace.agent_start.get: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
