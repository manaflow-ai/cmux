import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon

/// Where a started chat's Move to… can take it (wiring: the rule is Rust's ``CloudMoveTargetRules``,
/// the moves are ``CloudMove`` and ``CloudBringBack``).
@MainActor
enum CloudMoveTargets {
    static func targets(record: AgentSessionRef?, machine: String, services: AppServices) -> [AgentPaneMoveTarget] {
        guard let record, !record.host.hasPrefix(MachineRegistry.registryHostPrefix) || record.session.flatMap({ services.cloud.movedChats.entry(host: record.host, session: $0) }) != nil else { return [] } // a Cloud chat no move from here put there: no folder to take yet (cmux#40122)
        let running = record.host.hasPrefix(MachineRegistry.registryHostPrefix)
            ? services.machines.cloud.first { AgentTabStore.registryHost(of: $0.daemon) == record.host } : nil
        let chat = CloudMoveTargetRules.Chat(
            offered: AgentPaneMoveTarget.offered(signedIn: services.cloud.isSignedIn, loadedCurrent: services.cloud.hasLoadedCurrentMachines),
            started: record.session != nil, chief: record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix), running: running?.machineID,
            elsewhere: record.host.hasPrefix(MachineRegistry.registryHostPrefix) || !(machine.isEmpty || machine == MachineRegistry.localID),
            backHome: CloudBringBack.hiddenMenuItems(record, movedChats: services.cloud.movedChats).isEmpty,
            machines: services.machines.cloud.map { .init(id: $0.machineID, title: $0.machine.title, status: $0.machine.status.rawValue) })
        return CloudMoveTargetRules().targets(chat).map { .init(id: $0.id, label: $0.label, status: $0.status ?? "", kind: $0.kind) }
    }
}
