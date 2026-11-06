import Foundation

/// The mirror's `project` reply (cmux-layout-reducer `sidebar_doc::project`): one window's rows, regrouped in Rust
/// into the sections the list draws. Records come in their document wire form (`Section`, `Item`).
extension SidebarDocWire {
    nonisolated struct Projection: Decodable {
        var sections: [ProjectedSection]
        var machines: [String: [Node]]
        var items: [Member]
        var machineSections: [String: String]
        var machineOrder: [String]
        var unplaced: [SidebarDocWorkspaceRef]
        var bandGroups: [Group]
        var hostGroups: [String]
        var archived: [String]
        var groupSorts: [String: String]
        var pinnedInGroup: [String]

        enum CodingKeys: String, CodingKey {
            case sections, machines, items, unplaced, archived
            case machineSections = "machine_sections"
            case machineOrder = "machine_order"
            case bandGroups = "band_groups"
            case hostGroups = "host_groups"
            case groupSorts = "group_sorts"
            case pinnedInGroup = "pinned_in_group"
        }
    }

    /// The workspace list (`like`: the first machine section, whose spacing it shows), or a band section and its
    /// top-level items.
    nonisolated struct ProjectedSection: Decodable {
        var type: String
        var like: Section?
        var section: Section?
        var items: [BandItem]?
    }

    nonisolated struct BandItem: Decodable {
        var item: Item
        /// The space a Pinned link, tab or app draws in.
        var room: String?
    }

    nonisolated struct Member: Decodable {
        var ref: SidebarDocWorkspaceRef
        var item: String
    }

    /// A machine section's node: a workspace (its ref and item id), a group, or a link (its item record).
    nonisolated enum Node: Decodable {
        case workspace(SidebarDocWorkspaceRef, item: String)
        case group(Group)
        case link(Item)

        enum CodingKeys: String, CodingKey { case type, ref, item, group }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "workspace": self = .workspace(try c.decode(SidebarDocWorkspaceRef.self, forKey: .ref), item: try c.decode(String.self, forKey: .item))
            case "group": self = .group(try c.decode(Group.self, forKey: .group))
            default: self = .link(try c.decode(Item.self, forKey: .item))
            }
        }
    }

    nonisolated struct Group: Decodable {
        var id: String
        var name: String
        var color: String?
        var icon: String?
        var collapsed: Bool
        var section: String
        var pinned: Bool?
        var members: [Member]
        var listed: [Listed]
        var parent: String?
        var depth: Int
        var openMembers: [SidebarDocWorkspaceRef]
        var room: String?

        enum CodingKeys: String, CodingKey {
            case id, name, color, icon, collapsed, section, pinned, members, listed, parent, depth, room
            case openMembers = "open_members"
        }
    }

    nonisolated struct Listed: Decodable {
        var item: Item
        var after: String?
    }
}
