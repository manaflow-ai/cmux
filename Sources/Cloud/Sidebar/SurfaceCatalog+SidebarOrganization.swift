import Foundation

extension SurfaceCatalog {
    func sidebarNodes(unread: [String: Set<String>] = [:]) -> [CloudTreeNode] {
        CloudSidebarOrganizationTree(nodes: CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [],
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

    func raiseCloudSidebarNotification(machineID: String, terminalID: String) {
        let nodes = sidebarNodes()
        reconcileSidebarOrganization(on: .cloud(machineID), nodes: nodes)
        sidebarOrganization.raiseNotification(
            resource: SurfaceResourceID(machine: .cloud(machineID), kind: .terminal, key: terminalID),
            nodes: nodes
        )
    }
}
