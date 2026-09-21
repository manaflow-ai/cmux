import AppKit

extension CloudTreeOutlineView.Coordinator {
    /// Mouse, keyboard and status-button activation share the machine's current plan gate.
    func performPortAction(_ action: CloudPortsStatusAction, machineID: SurfaceMachineID) {
        guard let machine = machine(id: machineID) else { return }
        switch action {
        case .none: break
        case .refresh: nodeActions.refreshMachine(machineID)
        case .setupVPN:
            AppDelegate.shared?.openCloudVPNSetupWindow()
        case .openMachine, .openShell: openMachine(machine)
        }
    }

    func openMachine(_ machine: MachineSnapshot) {
        if machine.freeAccess == .expired {
            machineActions.promptUpgrade()
        } else {
            nodeActions.newTerminal(.cloud(machine.id), nil)
        }
    }
}
