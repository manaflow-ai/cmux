import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    /// Mouse, keyboard and status-button activation share the machine's current plan gate.
    func performPortAction(_ action: CloudPortsStatusAction, machineID: SurfaceMachineID) {
        switch action {
        case .none: break
        case .refresh: nodeActions.refreshMachine(machineID)
        case .setupVPN:
            AppDelegate.shared?.openCloudVPNSetupWindow()
        case .openMachine, .openShell:
            // Only opening needs the snapshot: it rejects removed machines and gates expired ones.
            guard let machine = machine(id: machineID) else { return }
            openMachine(machine)
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
