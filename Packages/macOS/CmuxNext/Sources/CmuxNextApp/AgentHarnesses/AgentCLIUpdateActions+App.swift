import CmuxNextAgentUpdates

extension AgentCLIUpdateActions {
    /// The module captures the owner route; the app supplies its daemons and strings.
    convenience init(services: AppServices) {
        self.init(daemons: .init(active: { [weak services] in services?.activeDaemon }, all: { [weak services] in services?.machines.daemons ?? [] },
                                 machine: { [weak services] in services?.machines.daemon(machine: $0) }),
                  unsupported: { AgentHarnessStrings.unsupported }, nothingToUpdate: { AgentHarnessStrings.nothingToUpdate },
                  stillUpdating: AgentHarnessStrings.stillUpdating, localMachine: MachineRegistry.localID)
    }
}
