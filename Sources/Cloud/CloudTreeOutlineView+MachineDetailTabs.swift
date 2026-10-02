import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    /// Opens `tab` on a machine's tab row, or closes it, then re-presents the
    /// current tree. Opening Ports refreshes the machine and asks for port
    /// discovery, as expanding the Ports group used to.
    func toggleMachineDetailTab(_ tab: CloudTreeMachineDetailTab, machine: SurfaceMachineID) {
        let opened = machineDetailLayout.toggle(tab, machine: machine)
        applyOrganization(nodes: organizationNodes)
        if opened == .ports {
            nodeActions.refreshMachine(machine)
            portsDemand.schedule(coordinator: self)
        }
    }
}
