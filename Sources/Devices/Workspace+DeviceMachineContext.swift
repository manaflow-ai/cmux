import Foundation

extension Workspace {
    /// A focused device pane wins; otherwise one unambiguous device badge owns Cmd-N.
    var deviceMachineForNewWorkspace: SurfaceMachineID? {
        let resources = cloudBindingState.projectedResources
        if let focusedPanelId, let machine = resources[focusedPanelId]?.machine, machine.isDevice {
            return machine
        }
        let devices = Set(resources.values.map(\.machine).filter(\.isDevice))
        return devices.count == 1 ? devices.first : nil
    }
}
