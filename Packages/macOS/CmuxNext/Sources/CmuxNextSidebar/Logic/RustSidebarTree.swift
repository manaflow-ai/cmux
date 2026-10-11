import Foundation

nonisolated struct RustWorkspace: Codable {
    var id: String
    var machine: String
}

nonisolated struct RustNode: Encodable {
    var kind: String
    var workspace: RustWorkspace?
    var id: String?
    var machine: String?
    var workspaces: [RustWorkspace]?

    init(_ node: SidebarNode) {
        switch node {
        case let .workspace(workspace):
            kind = "workspace"
            self.workspace = RustWorkspace(id: workspace.id.rawValue, machine: workspace.machineID.rawValue)
            id = nil
            machine = nil
            workspaces = nil
        case let .group(group):
            kind = "group"
            workspace = nil
            id = group.id.rawValue
            machine = group.workspaces.first?.machineID.rawValue
            workspaces = group.workspaces.map { RustWorkspace(id: $0.id.rawValue, machine: $0.machineID.rawValue) }
        }
    }
}

nonisolated struct RustSection: Encodable {
    var id: RustSectionID
    var machine: String?
    var nodes: [RustNode]

    init(_ section: SidebarSection) {
        id = RustSectionID(section.id)
        machine = section.machine?.id.rawValue
        nodes = section.nodes.map(RustNode.init)
    }
}
