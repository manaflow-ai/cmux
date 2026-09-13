import Foundation

extension SurfaceCatalog {
    func sidebarNodes(on machine: SurfaceMachineID? = nil, unread: [String: Set<String>] = [:]) -> [CloudTreeNode] {
        let input: SurfaceCatalogSnapshot
        if let machine {
            input = SurfaceCatalogSnapshot(
                machines: machines[machine].map { [$0] } ?? [],
                resources: (resourceIDsByMachine[machine] ?? []).compactMap { resources[$0] }.sorted { $0.catalogPrecedes($1) },
                projections: projections.filter { $0.resource.machine == machine }.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
            )
        } else {
            input = snapshot
        }
        return CloudSidebarOrganizationTree(nodes: CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: input, localWorkspaces: [],
            unreadTerminalIDs: unread, includeLocalMachine: false
        )).arrange(using: sidebarOrganization.state)
    }

    @discardableResult
    func organizeSidebar(_ action: CloudSidebarOrganizationAction, nodeID: String) -> Bool {
        let nodes = sidebarNodes()
        guard let parent = CloudSidebarOrganizationTree(nodes: nodes).parent(of: nodeID) else { return false }
        reconcileSidebarOrganization(on: parent.machine, nodes: nodes)
        return sidebarOrganization.perform(action, id: nodeID, nodes: nodes)
    }

    private func reconcileSidebarOrganization(on machine: SurfaceMachineID, nodes: [CloudTreeNode]) {
        guard cloudStateObservations[machine]?.freshness == .current, let state = cloudStates[machine] else { return }
        sidebarOrganization.reconcile(nodes: nodes, machine: machine, workspaceIDs: Set(state.workspaces.map(\.id)))
    }

    /// Called only after explicit deletion or authoritative fleet reconciliation.
    /// Sign-out continues to use unregister, retaining this Mac's preferences.
    func removeCloudMachine(_ machine: SurfaceMachineID) {
        guard !machine.isLocal else { return }
        sidebarOrganization.forget(machine: machine)
        unregister(machine: machine)
    }

    func raiseCloudSidebarNotification(machineID: String, terminalID: String) {
        let resource = SurfaceResourceID(machine: .cloud(machineID), kind: .terminal, key: terminalID)
        guard resources[resource] != nil else { return }
        sidebarNotifications.enqueue(resource)
    }

    func flushSidebarNotifications(on machine: SurfaceMachineID, resources pending: [SurfaceResourceID]) {
        let retained = pending.filter { resources[$0] != nil }
        guard !retained.isEmpty, machines[machine] != nil else { return }
        let nodes = sidebarNodes(on: machine)
        reconcileSidebarOrganization(on: machine, nodes: nodes)
        sidebarOrganization.raiseNotifications(resources: retained, nodes: nodes)
    }
}
