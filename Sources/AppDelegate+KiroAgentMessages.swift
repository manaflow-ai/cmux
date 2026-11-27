import CmuxFoundation
import Darwin
import Foundation

/// Verifies the recorded Kiro runtime owner before an inbox claim.
@MainActor
extension AppDelegate {
    func liveKiroAgentProcessMatchesSurface(identity: AgentPIDProcessIdentity, surfaceID: UUID) -> Bool {
        for manager in agentDeliveryTabManagers() {
            for workspace in manager.tabs {
                if workspace.agentRuntimeState(forPanelId: surfaceID)?.ownsKiroProcess(identity) == true {
                    return true
                }
            }
        }
        return DockSplitStore.liveStores.contains { dock in
            dock.agentRuntimeByPanelId[surfaceID]?.ownsKiroProcess(identity) == true
        }
    }
}

extension Workspace.DetachedAgentRuntimeState {
    /// PID reuse must not let a new process inherit the old Kiro session's inbox.
    func ownsKiroProcess(_ identity: AgentPIDProcessIdentity) -> Bool {
        agentPIDKeys.contains { key in
            (key == "kiro" || key.hasPrefix("kiro."))
                && agentPIDs[key] == identity.pid
                && agentPIDProcessIdentities[key] == identity
        }
    }
}
