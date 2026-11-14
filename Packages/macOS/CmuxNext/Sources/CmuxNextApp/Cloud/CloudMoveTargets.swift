import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextServer

/// Where a started chat's Move to… can take it (wiring: the rule is Rust's ``CloudMoveTargetRules``,
/// the moves are ``CloudMove``, ``CloudBringBack`` and ``SSHChatMoveRun``).
@MainActor
enum CloudMoveTargets {
    static func targets(record: AgentSessionRef?, machine: String, services: AppServices) -> [AgentPaneMoveTarget] {
        rules(record: record, machine: machine, services: services).map { .init(id: $0.id, label: $0.label, status: $0.status ?? "", kind: $0.kind) }
    }

    /// The rows with the action each runs.
    static func rules(record: AgentSessionRef?, machine: String, services: AppServices) -> [CloudMoveTargetRules.Target] {
        chat(record: record, machine: machine, services: services).map { CloudMoveTargetRules().targets($0) } ?? []
    }

    /// What the rule reads of the chat whose tab names `record`, on the daemon of `machine`.
    static func chat(record: AgentSessionRef?, machine: String, services: AppServices) -> CloudMoveTargetRules.Chat? {
        guard let record else { return nil }
        let registry = record.host.hasPrefix(MachineRegistry.registryHostPrefix)
        let running = registry ? services.machines.cloud.first { AgentTabStore.registryHost(of: $0.daemon) == record.host } : nil
        let onSSH = registry ? services.machines.ssh.first { AgentTabStore.registryHost(of: $0.daemon) == record.host } : nil
        return CloudMoveTargetRules.Chat(
            offered: AgentPaneMoveTarget.offered(signedIn: services.cloud.isSignedIn, loadedCurrent: services.cloud.hasLoadedCurrentMachines),
            started: record.session != nil, chief: record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix), running: running?.machineID,
            elsewhere: registry || !(machine.isEmpty || machine == MachineRegistry.localID),
            backHome: CloudBringBack.hiddenMenuItems(record, movedChats: services.cloud.movedChats).isEmpty,
            machines: services.machines.cloud.map { .init(id: $0.machineID, title: $0.machine.title, status: $0.machine.status.rawValue) },
            movedHere: record.session.flatMap { services.cloud.movedChats.entry(host: record.host, session: $0) } != nil,
            session: record.session, onSsh: onSSH?.machineID, peer: record.session.flatMap { services.agentLanes.lane($0)?.peer },
            ssh: sshMachines(services))
    }

    /// The sidebar's SSH machines, then the acpmux peers Settings > Devices lists (`cmux setup machine`
    /// adds only the peer); Rust lists a machine named both ways once.
    private static func sshMachines(_ services: AppServices) -> [CloudMoveTargetRules.SSHMachine] {
        let sidebar = services.machines.ssh.map { session in
            CloudMoveTargetRules.SSHMachine(id: session.machineID, title: services.machines.machineName(session.machineID) ?? session.host.label,
                                            online: session.linkStatus == .connected,
                                            names: [session.host.destination.host, session.host.destination.displayName, session.host.label])
        }
        let peers = (services.devices.listing?.devices ?? []).filter { $0.id.hasPrefix(DeviceDirectory.peerPrefix) }.map {
            CloudMoveTargetRules.SSHMachine(id: $0.id, title: $0.name, online: $0.state == "connected", names: [$0.name])
        }
        return sidebar + peers
    }
}
