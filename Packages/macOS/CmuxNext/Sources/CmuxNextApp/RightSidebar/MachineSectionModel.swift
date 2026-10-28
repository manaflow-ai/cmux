import CmuxNextServer

extension MachineSectionModel {
    /// The rows of `machines` now, each with its last check from `health`.
    static func rows(_ machines: MachineRegistry, health: MachineHealthStore) -> [MachineSectionRow] {
        machines.daemons.map { daemon in
            let connected = if case .connected = daemon.store.connectionState { true } else { false }
            let name = daemon.isLocal ? RightSidebarStrings.thisMac : machines.machineName(daemon.machineID) ?? daemon.machineID
            let report = health.reports[daemon.machineID]
            return MachineSectionRow(id: daemon.machineID, name: name, isConnected: connected, isLocal: daemon.isLocal,
                                     health: report?.health, healthStep: report?.worstStep?.step)
        }
    }
}
