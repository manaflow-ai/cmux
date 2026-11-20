import CmuxNextDesign
import Foundation

/// One window's sidebar as it last looked, saved so the next launch draws
/// it in the first frame (snapshot-first launch): sections, groups, each row's title, icon and what sets
/// its height and Done fold (`SidebarWorkspaceSnapshot`), plus the space (profile) bar. Other live detail
/// (activity, unread counts, agent state) arrives with the daemon. Rows read back as `SidebarRowState.stale`.
package nonisolated struct SidebarSnapshot: Codable, Hashable, Sendable {
    package var sections: [Section]
    package var profiles: [Profile]
    package var activeProfileID: String?

    package struct Section: Codable, Hashable, Sendable {
        /// Nil for the pinned section.
        package var machineID: String?
        package var machineName: String?
        /// `local`, `cloud` or `ssh`.
        package var machineKind: String?
        package var isCollapsed: Bool
        package var nodes: [Node]
    }

    /// A loose workspace, or a group with its workspaces.
    package struct Node: Codable, Hashable, Sendable {
        package var workspace: Workspace?
        package var group: Group?
    }

    package typealias Workspace = SidebarWorkspaceSnapshot

    package struct Group: Codable, Hashable, Sendable {
        package var id: String
        package var name: String
        package var color: String
        package var isCollapsed: Bool
        package var isPinned: Bool
        package var workspaces: [Workspace]
    }

    package struct Profile: Codable, Hashable, Sendable {
        package var id: String
        package var name: String
        package var color: String?
        package var icon: String?
    }

    package init(sections: [Section], profiles: [Profile], activeProfileID: String?) {
        self.sections = sections
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    /// Captures what the sidebar shows now. Placeholder rows are not saved.
    package init(sections: [SidebarSection], profiles: [SidebarProfile], activeProfileID: ProfileKey?) {
        self.sections = sections.filter { !$0.isDocSection }.map { section in // document sections come back with the document
            Section(machineID: section.machine?.id.rawValue, machineName: section.machine?.name,
                    machineKind: section.machine.map { Self.kindName($0.kind) }, isCollapsed: section.isCollapsed,
                    nodes: section.nodes.compactMap(Self.node))
        }
        self.profiles = profiles.map { Profile(id: $0.id.rawValue, name: $0.name, color: $0.color?.rawValue, icon: $0.icon) }
        self.activeProfileID = activeProfileID?.rawValue
    }

    /// The saved sections as sidebar sections: every row `.stale`, every
    /// machine header connecting.
    package var sidebarSections: [SidebarSection] {
        sections.map { section in
            let nodes = section.nodes.compactMap(Self.sidebarNode)
            guard let id = section.machineID else { return SidebarSection(kind: .pinned, isCollapsed: section.isCollapsed, nodes: nodes) }
            let machine = SidebarMachine(id: MachineID(id), name: section.machineName ?? "", kind: Self.kind(section.machineKind),
                                         status: .connecting)
            return SidebarSection(kind: .machine(machine), isCollapsed: section.isCollapsed, nodes: nodes)
        }
    }

    package var sidebarProfiles: [SidebarProfile] {
        profiles.map { SidebarProfile(id: ProfileKey($0.id), name: $0.name, color: $0.color.flatMap(GroupColor.init(rawValue:)), icon: $0.icon) }
    }

    package var sidebarActiveProfileID: ProfileKey? { activeProfileID.map(ProfileKey.init) }

    /// Every saved workspace id, in order.
    package var workspaceIDs: [String] {
        sections.flatMap(\.nodes).flatMap { node in node.workspace.map { [$0] } ?? node.group?.workspaces ?? [] }.map(\.id)
    }

    /// How many workspace rows are saved.
    package var rowCount: Int {
        sections.reduce(0) { total, section in
            section.nodes.reduce(total) { $0 + ($1.workspace != nil ? 1 : $1.group?.workspaces.count ?? 0) }
        }
    }

    /// Every row reduced to what places it (`SidebarWorkspaceSnapshot.compacted`).
    package func compactingRows() -> SidebarSnapshot {
        var copy = self
        for s in copy.sections.indices {
            copy.sections[s].nodes = copy.sections[s].nodes.map { node in
                Node(workspace: node.workspace?.compacted, group: node.group.map { group in
                    var group = group
                    group.workspaces = group.workspaces.map(\.compacted)
                    return group
                })
            }
        }
        return copy
    }

    /// The first `limit` rows in sidebar order (top first, what the first frame shows); a group past
    /// the limit goes with its rows.
    package func keepingFirstRows(_ limit: Int) -> SidebarSnapshot {
        var copy = self
        var left = max(0, limit)
        for s in copy.sections.indices {
            var kept: [Node] = []
            for node in copy.sections[s].nodes where left > 0 {
                if node.workspace != nil {
                    left -= 1
                    kept.append(node)
                } else if var group = node.group {
                    group.workspaces = Array(group.workspaces.prefix(left))
                    left -= group.workspaces.count
                    kept.append(Node(workspace: nil, group: group))
                }
            }
            copy.sections[s].nodes = kept
        }
        return copy
    }

    private static func node(_ node: SidebarNode) -> Node? {
        switch node {
        case let .workspace(ws):
            guard !ws.rowState.isPending else { return nil }
            return Node(workspace: Workspace(row: ws), group: nil)
        case let .group(group):
            let rows = group.workspaces.filter { !$0.rowState.isPending }.map(Workspace.init(row:))
            return Node(workspace: nil, group: Group(id: group.id.rawValue, name: group.name, color: group.color.rawValue,
                                                     isCollapsed: group.isCollapsed, isPinned: group.isPinned, workspaces: rows))
        case .item:
            return nil // a document item: the document keeps it
        }
    }

    private static func sidebarNode(_ node: Node) -> SidebarNode? {
        if let ws = node.workspace { return .workspace(ws.restoredRow) }
        guard let group = node.group else { return nil }
        return .group(SidebarGroup(id: GroupID(group.id), name: group.name, color: GroupColor(rawValue: group.color) ?? .grey,
                                   isCollapsed: group.isCollapsed, isPinned: group.isPinned,
                                   workspaces: group.workspaces.map(\.restoredRow)))
    }

    private static func kindName(_ kind: SidebarMachine.Kind) -> String {
        switch kind {
        case .local: "local"
        case .cloud: "cloud"
        case .ssh: "ssh"
        case .server: "server"
        }
    }

    private static func kind(_ name: String?) -> SidebarMachine.Kind {
        switch name {
        case "cloud": .cloud
        case "ssh": .ssh
        case "server": .server
        default: .local
        }
    }
}
