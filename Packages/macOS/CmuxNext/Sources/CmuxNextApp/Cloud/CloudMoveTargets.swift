import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon

/// Where a started chat's Move to… can take it, from the live machine list (wiring: the page draws
/// the rows, the moves are ``CloudMove`` and ``CloudBringBack``). A chat of this Mac moves to any of
/// the account's Cloud machines; a Cloud machine's chat moves to any other one, and back to this Mac
/// when a move from here put it there (its label is empty: the page names this Mac). A machine that
/// is going away or failed is not listed.
@MainActor
enum CloudMoveTargets {
    static func targets(record: AgentSessionRef?, machine: String, services: AppServices) -> [AgentPaneMoveTarget] {
        guard let record, record.session != nil, !record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix),
              AgentPaneMoveTarget.offered(signedIn: services.cloud.isSignedIn, loadedCurrent: services.cloud.hasLoadedCurrentMachines)
        else { return [] }
        let running = CloudMove.runningMachine(record, services)
        // A chat of another kind of machine (an SSH peer, a paired server) has no Cloud move.
        if running == nil, record.host.hasPrefix(MachineRegistry.registryHostPrefix) || !(machine.isEmpty || machine == MachineRegistry.localID) {
            return []
        }
        var targets: [AgentPaneMoveTarget] = []
        if running != nil, CloudBringBack.hiddenMenuItems(record, movedChats: services.cloud.movedChats).isEmpty {
            targets.append(AgentPaneMoveTarget(id: AgentPaneMoveTarget.localID, label: "", kind: "local"))
        }
        for session in services.machines.cloud where session.machineID != running?.machineID {
            let status = session.machine.status
            guard ![.failed, .destroyed, .deleting].contains(status) else { continue }
            targets.append(AgentPaneMoveTarget(id: session.machineID, label: session.machine.title, status: status.rawValue))
        }
        return targets
    }
}
