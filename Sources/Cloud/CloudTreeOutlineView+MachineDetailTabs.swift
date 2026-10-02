import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    /// Opens `tab` on a machine's tab row, or closes it, then re-presents the
    /// current tree. Opening Ports or Displays refreshes the machine, as
    /// expanding their groups used to, and Ports also asks for port discovery.
    func toggleMachineDetailTab(_ tab: CloudTreeMachineDetailTab, machine: SurfaceMachineID) {
        let opened = machineDetailLayout.toggle(tab, machine: machine)
        applyOrganization(nodes: organizationNodes)
        if opened == .ports || opened == .displays {
            nodeActions.refreshMachine(machine)
        }
        if opened == .ports {
            portsDemand.schedule(coordinator: self)
        }
    }
}
