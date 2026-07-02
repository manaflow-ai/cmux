import CmuxWorkspaces
import Foundation

/// The window-side host for the CmuxWorkspaces agent-PID liveness sweep: the
/// main-actor snapshot read of every workspace's agent-PID map, and the apply
/// of the stale clears the off-main `kill(pid, 0)` probe found.
///
/// Lifts the read/write halves of the legacy `TabManager.sweepStaleAgentPIDs()`
/// loop one-for-one. The apply re-reads the live workspace by id (rather than
/// trusting the probed snapshot) and clears a key only when its current pid
/// still equals the pid the off-main probe found dead, so a key reassigned to a
/// fresh live agent during the probe window is not clobbered; a gone workspace
/// makes its clear a no-op, matching the legacy `for tab in tabs` iteration over
/// the live array. The pid re-check restores the legacy's effective read/clear
/// atomicity, which ran in one synchronous main-actor turn.
extension TabManager: AgentPIDLivenessSweepHosting {
    func agentPIDSnapshot() -> [UUID: [String: pid_t]] {
        var snapshot: [UUID: [String: pid_t]] = [:]
        for tab in tabs {
            snapshot[tab.id] = tab.agentPIDs
        }
        return snapshot
    }

    func applyStaleAgentPIDs(_ staleByWorkspace: [UUID: [String: pid_t]]) {
        for (workspaceId, staleKeys) in staleByWorkspace {
            guard !staleKeys.isEmpty else { continue }
            guard let tab = tabs.first(where: { $0.id == workspaceId }) else { continue }
            var clearedAny = false
            for (key, probedDeadPid) in staleKeys {
                // Re-validate against the live map: the off-main probe may have
                // completed before `recordAgentPID` reassigned this key to a
                // fresh live agent (e.g. a SIGKILLed agent that respawned). Only
                // clear when the current pid still matches the one probed dead,
                // matching the legacy synchronous read->kill->clear turn.
                guard tab.agentPIDs[key] == probedDeadPid else { continue }
                tab.clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
                clearedAny = true
            }
            guard clearedAny else { continue }
            let remainingAgentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
            PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: remainingAgentPIDs)
            // Also clear stale notifications (e.g. "Doing well, thanks!")
            // left behind when Claude was killed without SessionEnd firing.
            appEnvironment?.notificationStore?.clearNotifications(forTabId: tab.id)
        }
    }
}
