public import CmuxNextDesign
import Foundation

/// The Swift side of the shared sidebar tree edits (`cmux-layout-reducer` `sidebar_edits`, JSON op `sidebar_edits`).
/// A call sends a skeleton of the sections (ids, machines, a group's members and flags) and rebuilds the rows from
/// the reply by id, so row content never crosses. An item row is named by its place in the request (`ref`).
nonisolated struct RustSidebarEdits {
    /// The request's skeleton and the rows it names.
    private(set) var sections: [RustEditSection] = []
    /// Each id's rows in tree order: a workspace can be listed twice (Pinned and its machine), and each listing
    /// keeps its own row. Every shared edit keeps the tree order of one id's listings (a move takes them all out in
    /// tree order and puts them back together), so the reply's n-th listing of an id is the request's n-th.
    private var workspaces: [WorkspaceID: [SidebarWorkspace]] = [:]
    private var groups: [GroupID: SidebarGroup] = [:]
    private var items: [SidebarListItem] = []

    init(_ sections: [SidebarSection]) {
        for section in sections {
            var nodes: [RustEditNode] = []
            nodes.reserveCapacity(section.nodes.count)
            for node in section.nodes { nodes.append(self.node(node)) }
            self.sections.append(RustEditSection(id: RustSectionID(section.id), collapsed: section.isCollapsed, nodes: nodes))
        }
    }

    private mutating func node(_ node: SidebarNode) -> RustEditNode {
        switch node {
        case let .workspace(ws):
            return .workspace(workspace(ws))
        case let .item(item):
            return .item(ref(item))
        case let .group(group):
            if groups[group.id] == nil { groups[group.id] = group }
            var members: [RustEditMember] = []
            for member in group.members {
                switch member {
                case let .workspace(ws): members.append(.workspace(workspace(ws)))
                case let .item(item): members.append(.item(ref(item)))
                }
            }
            return .group(RustEditGroup(id: group.id.rawValue, name: group.name, parent: group.parent?.rawValue,
                                        pinned: group.isPinned, collapsed: group.isCollapsed, members: members))
        }
    }

    private mutating func workspace(_ ws: SidebarWorkspace) -> RustEditWorkspace {
        workspaces[ws.id, default: []].append(ws)
        return RustEditWorkspace(id: ws.id.rawValue, machine: ws.machineID.rawValue)
    }

    private mutating func ref(_ item: SidebarListItem) -> Int {
        items.append(item)
        return items.count - 1
    }

    /// `sections` as the reply lists them: each known row and group as it was, in its new place; a new group from
    /// `made` (its id, name and tint), a new Pinned section empty.
    func rebuild(_ reply: [RustEditSection], from old: [SidebarSection], made: (GroupID) -> SidebarGroup?) -> [SidebarSection] {
        var listed: [WorkspaceID: Int] = [:]
        func row(_ wire: RustEditWorkspace) -> SidebarWorkspace? {
            let id = WorkspaceID(wire.id)
            guard let rows = workspaces[id] else { return nil }
            let n = listed[id, default: 0]
            listed[id] = n + 1
            return rows.dropFirst(n).first ?? rows.last
        }
        return reply.compactMap { shown in
            guard let id = shown.id.swiftValue else { return nil }
            var section = old.first { $0.id == id } ?? SidebarSection(kind: .pinned, nodes: [])
            section.isCollapsed = shown.collapsed
            section.nodes = shown.nodes.compactMap { node in
                switch node {
                case let .workspace(ws): return row(ws).map(SidebarNode.workspace)
                case let .item(ref): return items.indices.contains(ref) ? .item(items[ref]) : nil
                case let .group(skeleton):
                    let id = GroupID(skeleton.id)
                    guard var group = groups[id] ?? made(id) else { return nil }
                    group.isPinned = skeleton.pinned
                    group.isCollapsed = skeleton.collapsed
                    // A subgroup whose parent left lists at the top level (the shared rules clear it); the depth
                    // pass (`resolvingGroupDepths`) sets `depth` from this.
                    group.parent = skeleton.parent.map(GroupID.init)
                    group.setMembers(skeleton.members.compactMap { member in
                        switch member {
                        case let .workspace(ws): row(ws).map(SidebarGroupMember.workspace)
                        case let .item(ref): items.indices.contains(ref) ? .item(items[ref]) : nil
                        }
                    })
                    return .group(group)
                }
            }
            return section
        }
    }
}

nonisolated struct RustEditSection: Codable {
    var id: RustSectionID
    var collapsed: Bool
    var nodes: [RustEditNode]
}

nonisolated struct RustEditWorkspace: Codable {
    var id: String
    var machine: String
}

nonisolated struct RustEditGroup: Codable {
    var id: String
    var name: String
    var parent: String?
    var pinned: Bool
    var collapsed: Bool
    var members: [RustEditMember]
}

nonisolated enum RustEditMember: Codable {
    case workspace(RustEditWorkspace)
    case item(Int)

    private enum Keys: String, CodingKey { case kind, workspace, ref }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "workspace": self = try .workspace(container.decode(RustEditWorkspace.self, forKey: .workspace))
        default: self = try .item(container.decode(Int.self, forKey: .ref))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .workspace(ws):
            try container.encode("workspace", forKey: .kind)
            try container.encode(ws, forKey: .workspace)
        case let .item(ref):
            try container.encode("item", forKey: .kind)
            try container.encode(ref, forKey: .ref)
        }
    }
}

nonisolated enum RustEditNode: Codable {
    case workspace(RustEditWorkspace)
    case group(RustEditGroup)
    case item(Int)

    private enum Keys: String, CodingKey { case kind, workspace, group, ref }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "workspace": self = try .workspace(container.decode(RustEditWorkspace.self, forKey: .workspace))
        case "group": self = try .group(container.decode(RustEditGroup.self, forKey: .group))
        default: self = try .item(container.decode(Int.self, forKey: .ref))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .workspace(ws):
            try container.encode("workspace", forKey: .kind)
            try container.encode(ws, forKey: .workspace)
        case let .group(group):
            try container.encode("group", forKey: .kind)
            try container.encode(group, forKey: .group)
        case let .item(ref):
            try container.encode("item", forKey: .kind)
            try container.encode(ref, forKey: .ref)
        }
    }
}

nonisolated struct RustEditPosition: Codable, Equatable {
    var section: RustSectionID
    var group: String?
    var index: Int

    init(_ position: DropPosition) {
        section = RustSectionID(position.section)
        group = position.group?.rawValue
        index = position.index
    }

    var swiftValue: DropPosition? {
        section.swiftValue.map { DropPosition(section: $0, group: group.map(GroupID.init), index: index) }
    }
}

/// The structural intents the shared edits take (`sidebar_edits::Intent`).
nonisolated struct RustEditIntent: Encodable {
    var kind: String
    var ids: [String]?
    var position: RustEditPosition?
    var group: String?
    var index: Int?
    var id: String?
    var anchor: String?
    var collapsed: Bool?
    var pinned: Bool?
    var section: RustSectionID?

    init(kind: String) { self.kind = kind }

    /// Nil for an intent with no tree edit (a field write, a view or app action).
    init?(_ intent: SidebarIntent) {
        switch intent {
        case let .reorder(ids, position):
            self.init(kind: "reorder")
            (self.ids, self.position) = (ids.map(\.rawValue), RustEditPosition(position))
        case let .move(ids, group):
            self.init(kind: "move")
            (self.ids, self.group) = (ids.map(\.rawValue), group.rawValue)
        case let .reorderGroup(group, index):
            self.init(kind: "reorder_group")
            (self.group, self.index) = (group.rawValue, index)
        case let .createGroup(id, _, _, ids, anchor, collapsed, index):
            self.init(kind: "create_group")
            (self.id, self.ids, self.anchor, self.collapsed, self.index) = (id.rawValue, ids.map(\.rawValue), anchor?.rawValue, collapsed, index)
        case let .ungroup(group):
            self.init(kind: "ungroup")
            self.group = group.rawValue
        case let .closeGroup(group):
            self.init(kind: "close_group")
            self.group = group.rawValue
        case let .close(ids):
            self.init(kind: "close")
            self.ids = ids.map(\.rawValue)
        case let .setPinned(ids, pinned):
            self.init(kind: "set_pinned")
            (self.ids, self.pinned) = (ids.map(\.rawValue), pinned)
        case let .setGroupPinned(group, pinned):
            self.init(kind: "set_group_pinned")
            (self.group, self.pinned) = (group.rawValue, pinned)
        case let .toggleCollapse(.section(section)):
            self.init(kind: "toggle_section")
            self.section = RustSectionID(section)
        case let .toggleCollapse(.group(group)):
            self.init(kind: "toggle_group")
            self.group = group.rawValue
        default:
            return nil
        }
    }
}

/// One `sidebar_edits` call (`sidebar_edits::Request`, tagged by `op`).
nonisolated struct RustEditRequest: Encodable {
    var op: String
    var sections: [RustEditSection]?
    var intent: RustEditIntent?
    var prunes: Bool?
    var ids: [String]?
    var direction: String?
    var group: String?
    var step: String?
    var keeping: String?
    var id: String?
    var name: String?
    var machine: String?
    var sidebars: [[RustNamedGroup]]?
    var localIndex: Int?
    var local: [String]?
    var global: [String]?
    var moving: [String]?
    var shown: [String]?
    var rowed: [String]?

    init(_ op: String, sections: [RustEditSection]? = nil) {
        self.op = op
        self.sections = sections
    }

    enum CodingKeys: String, CodingKey {
        case op, sections, intent, prunes, ids, direction, group, step, keeping, id, name, machine, sidebars, local, global, moving, shown, rowed
        case localIndex = "local_index"
    }
}

nonisolated struct RustEditReply: Decodable {
    var changed: Bool
    var sections: [RustEditSection]?
}

nonisolated struct RustNamedGroup: Encodable {
    var name: String
    var rows: [RustNamedRow]
}

nonisolated struct RustNamedRow: Encodable {
    var id: String
    var title: String
    var machine: String
}

nonisolated struct RustPersonalPlacement: Decodable {
    var key: String
    var index: Int
}
