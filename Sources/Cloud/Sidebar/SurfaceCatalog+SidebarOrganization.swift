import Foundation

extension SurfaceCatalog {
    func sidebarNodes(unread: [String: Set<String>] = [:]) -> [CloudTreeNode] {
        CloudSidebarOrganizationTree(nodes: CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [],
            unreadTerminalIDs: unread, includeLocalMachine: false
        )).arrange(using: sidebarOrganization.state)
    }

    func raiseCloudSidebarNotification(machineID: String, terminalID: String) {
        sidebarOrganization.raiseNotification(
            resource: SurfaceResourceID(machine: .cloud(machineID), kind: .terminal, key: terminalID),
            nodes: sidebarNodes()
        )
    }
}
