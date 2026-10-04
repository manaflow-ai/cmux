import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// One window's sidebar as it last looked, saved so the next launch draws
/// it in the first frame (snapshot-first launch): sections, groups and the
/// title and icon of each row, plus the space (profile) bar. Live-only
/// detail (status lines, activity, unread counts, cwd) is never saved; it
/// arrives with the daemon. Rows read back as `SidebarRowState.stale`.
nonisolated struct SidebarSnapshot: Codable, Hashable, Sendable {
    var sections: [Section]
    var profiles: [Profile]
    var activeProfileID: String?

    struct Section: Codable, Hashable, Sendable {
        /// Nil for the pinned section.
        var machineID: String?
        var machineName: String?
        /// `local`, `cloud` or `ssh`.
        var machineKind: String?
        var isCollapsed: Bool
        var nodes: [Node]
    }

    /// A loose workspace, or a group with its workspaces.
    struct Node: Codable, Hashable, Sendable {
        var workspace: Workspace?
        var group: Group?
    }

    struct Workspace: Codable, Hashable, Sendable {
        var id: String
        var machineID: String
        var title: String
        /// `symbol:<name>`, `swatch:<color>` or `emoji:<text>`.
        var icon: String?
        var iconTint: String?
    }

    struct Group: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var color: String
        var isCollapsed: Bool
        var isPinned: Bool
        var workspaces: [Workspace]
    }

    struct Profile: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var color: String?
        var icon: String?
    }

    init(sections: [Section], profiles: [Profile], activeProfileID: String?) {
        self.sections = sections
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    /// Captures what the sidebar shows now. Placeholder rows are not saved.
    init(sections: [SidebarSection], profiles: [SidebarProfile], activeProfileID: ProfileKey?) {
        self.sections = sections.map { section in
            Section(machineID: section.machine?.id.rawValue, machineName: section.machine?.name,
                    machineKind: section.machine.map { Self.kindName($0.kind) }, isCollapsed: section.isCollapsed,
                    nodes: section.nodes.compactMap(Self.node))
        }
        self.profiles = profiles.map { Profile(id: $0.id.rawValue, name: $0.name, color: $0.color?.rawValue, icon: $0.icon) }
        self.activeProfileID = activeProfileID?.rawValue
    }

    /// The saved sections as sidebar sections: every row `.stale`, every
    /// machine header connecting.
    var sidebarSections: [SidebarSection] {
        sections.map { section in
            let nodes = section.nodes.compactMap(Self.sidebarNode)
            guard let id = section.machineID else { return SidebarSection(kind: .pinned, isCollapsed: section.isCollapsed, nodes: nodes) }
            let machine = SidebarMachine(id: MachineID(id), name: section.machineName ?? "", kind: Self.kind(section.machineKind),
                                         status: .connecting)
            return SidebarSection(kind: .machine(machine), isCollapsed: section.isCollapsed, nodes: nodes)
        }
    }

    var sidebarProfiles: [SidebarProfile] {
        profiles.map { SidebarProfile(id: ProfileKey($0.id), name: $0.name, color: $0.color.flatMap(GroupColor.init(rawValue:)), icon: $0.icon) }
    }

    var sidebarActiveProfileID: ProfileKey? { activeProfileID.map(ProfileKey.init) }

    /// Every saved workspace id, in order.
    var workspaceIDs: [String] {
        sections.flatMap(\.nodes).flatMap { node in node.workspace.map { [$0] } ?? node.group?.workspaces ?? [] }.map(\.id)
    }

    private static func node(_ node: SidebarNode) -> Node? {
        switch node {
        case let .workspace(ws):
            guard ws.rowState != .placeholder else { return nil }
            return Node(workspace: workspace(ws), group: nil)
        case let .group(group):
            let rows = group.workspaces.filter { $0.rowState != .placeholder }.map(workspace)
            return Node(workspace: nil, group: Group(id: group.id.rawValue, name: group.name, color: group.color.rawValue,
                                                     isCollapsed: group.isCollapsed, isPinned: group.isPinned, workspaces: rows))
        }
    }

    private static func sidebarNode(_ node: Node) -> SidebarNode? {
        if let ws = node.workspace { return .workspace(sidebarWorkspace(ws)) }
        guard let group = node.group else { return nil }
        return .group(SidebarGroup(id: GroupID(group.id), name: group.name, color: GroupColor(rawValue: group.color) ?? .grey,
                                   isCollapsed: group.isCollapsed, isPinned: group.isPinned,
                                   workspaces: group.workspaces.map(sidebarWorkspace)))
    }

    private static func workspace(_ ws: SidebarWorkspace) -> Workspace {
        var icon: String?
        var tint: String?
        switch ws.icon {
        case let .symbol(name, color)?:
            icon = "symbol:" + name
            tint = color?.rawValue
        case let .swatch(color)?: icon = "swatch:" + color.rawValue
        case let .emoji(text, chip)?:
            icon = "emoji:" + text
            tint = chip?.rawValue
        case nil: break
        }
        return Workspace(id: ws.id.rawValue, machineID: ws.machineID.rawValue, title: ws.title, icon: icon, iconTint: tint)
    }

    private static func sidebarWorkspace(_ ws: Workspace) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(ws.id), machineID: MachineID(ws.machineID), title: ws.title,
                         icon: ws.icon.flatMap { icon($0, tint: ws.iconTint) }, rowState: .stale)
    }

    private static func icon(_ value: String, tint: String?) -> WorkspaceIcon? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let kind = value[..<colon]
        let rest = String(value[value.index(after: colon)...])
        switch kind {
        case "symbol": return .symbol(rest, tint: tint.flatMap(GroupColor.init(rawValue:)))
        case "swatch": return GroupColor(rawValue: rest).map(WorkspaceIcon.swatch)
        case "emoji": return .emoji(rest, chip: tint.flatMap(GroupColor.init(rawValue:)))
        default: return nil
        }
    }

    private static func kindName(_ kind: SidebarMachine.Kind) -> String {
        switch kind {
        case .local: "local"
        case .cloud: "cloud"
        case .ssh: "ssh"
        }
    }

    private static func kind(_ name: String?) -> SidebarMachine.Kind {
        switch name {
        case "cloud": .cloud
        case "ssh": .ssh
        default: .local
        }
    }
}
