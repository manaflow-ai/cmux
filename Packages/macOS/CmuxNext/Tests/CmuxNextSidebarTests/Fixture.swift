import CoreGraphics
@testable import CmuxNextSidebar

// Fixture:
//   pinned: p1
//   local:  a, G1{g1,g2,g3}, b, G2(collapsed){h1,h2}, c
//   cloud:  x, y
let cloud = MachineID("cloud")

func w(_ id: String, _ machine: MachineID = .local) -> SidebarWorkspace {
    SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: id, directory: "sub-\(id)")
}

func id(_ s: String) -> WorkspaceID { WorkspaceID(s) }

let g1 = GroupID("G1")
let g2 = GroupID("G2")
let local = SectionID.machine(.local)
let cloudSection = SectionID.machine(cloud)

func fixture() -> [SidebarSection] {
    [
        SidebarSection(kind: .pinned, nodes: [.workspace(w("p1"))]),
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: [
            .workspace(w("a")),
            .group(SidebarGroup(id: g1, name: "G1", color: .purple, workspaces: [w("g1"), w("g2"), w("g3")])),
            .workspace(w("b")),
            .group(SidebarGroup(id: g2, name: "G2", color: .green, isCollapsed: true, workspaces: [w("h1"), w("h2")])),
            .workspace(w("c")),
        ]),
        SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud)), nodes: [
            .workspace(w("x", cloud)),
            .workspace(w("y", cloud)),
        ]),
    ]
}

/// Compact description of a section: loose ids and groups as `G1[g1,g2]`.
func shape(_ sections: [SidebarSection], _ section: SectionID) -> String {
    guard let s = sections.first(where: { $0.id == section }) else { return "<missing>" }
    return s.nodes.map { node -> String in
        switch node {
        case let .workspace(ws): ws.id.rawValue
        case let .group(g): "\(g.id.rawValue)[\(g.workspaces.map(\.id.rawValue).joined(separator: ","))]"
        }
    }.joined(separator: " ")
}

