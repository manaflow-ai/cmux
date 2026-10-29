import Darwin
import Foundation

/// Verifies the recorded Kiro runtime owner before an inbox claim.
@MainActor
extension AppDelegate {
    /// Confirms that a process is the active Kiro runtime recorded for a
    /// surface. A controlling TTY identifies the pane, but two Kiro processes
    /// can share that pane; inbox claims need the runtime owner as well.
    func liveKiroAgentProcessMatchesSurface(pid: pid_t, surfaceID: UUID) -> Bool {
        for manager in agentDeliveryTabManagers() {
            for workspace in manager.tabs {
                guard workspace.agentPIDPanelIdsByKey.values.contains(surfaceID) else { continue }
                for (key, recordedPID) in workspace.agentPIDs where recordedPID == pid {
                    guard key == "kiro" || key.hasPrefix("kiro.") else { continue }
                    if workspace.agentPIDPanelIdsByKey[key] == surfaceID { return true }
                }
            }
        }
        for dock in DockSplitStore.liveStores {
            guard let runtime = dock.agentRuntimeByPanelId[surfaceID] else { continue }
            if runtime.agentPIDs.contains(where: { key, recordedPID in
                (key == "kiro" || key.hasPrefix("kiro.")) && recordedPID == pid
            }) {
                return true
            }
        }
        return false
    }
}
