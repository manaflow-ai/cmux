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

extension SidebarDocWire.Projection {
    /// Leaves out the items `draws` refuses, with a left-out group's members. The mirror's shown document holds every
    /// pending add, but the sidebar draws only a workspace, the Chief (with the groups its pending add puts back) and an
    /// item whose record the pending writes hold (`SidebarDocStore.shownRecords`); another added item (Settings, a
    /// link) draws at its echo.
    mutating func keep(_ draws: (String) -> Bool) {
        func keeps(_ item: SidebarDocWire.Item) -> Bool { item.body.tag == "workspace" || draws(item.id) }
        for index in sections.indices { sections[index].items?.removeAll { !keeps($0.item) } }
        machines = machines.mapValues { nodes in
            nodes.compactMap { node -> SidebarDocWire.Node? in
                switch node {
                case .workspace: node
                case let .group(group): draws(group.id) ? .group(group.keeping(keeps)) : nil
                case let .link(item): keeps(item) ? node : nil
                }
            }
        }
        bandGroups = bandGroups.filter { draws($0.id) }.map { $0.keeping(keeps) }
    }
}

extension SidebarDocWire.Group {
    func keeping(_ keeps: (SidebarDocWire.Item) -> Bool) -> Self {
        var group = self
        group.listed.removeAll { !keeps($0.item) }
        return group
    }
}

/// The mirror's `project` answer as splices (cmux-layout-reducer `sidebar_doc::view_splice`): per list of the
/// projection, the element ranges to replace since the last answer, applied in order; the small fields only when
/// they changed. Swift only applies them: which rows show, and where, stays the reducer's.
extension SidebarDocWire {
    nonisolated struct Splice<Element: Decodable>: Decodable {
        var at: Int
        var remove: Int
        var insert: [Element]
    }

    nonisolated struct SpliceFields: Decodable {
        /// The section shapes; a band section's items are its `bands` list.
        var sections: [ProjectedSection]?
        var machineSections: [String: String]?
        var machineOrder: [String]?
        var hostGroups: [String]?
        var groupSorts: [String: String]?
        var pinnedInGroup: [String]?

        enum CodingKeys: String, CodingKey {
            case sections
            case machineSections = "machine_sections"
            case machineOrder = "machine_order"
            case hostGroups = "host_groups"
            case groupSorts = "group_sorts"
            case pinnedInGroup = "pinned_in_group"
        }
    }

    nonisolated struct SpliceAnswer: Decodable {
        var reset: Bool?
        var items: [Splice<Member>]?
        var archived: [Splice<String>]?
        var bandGroups: [Splice<Group>]?
        var unplaced: [Splice<SidebarDocWorkspaceRef>]?
        var machines: [String: [Splice<Node>]]?
        var bands: [String: [Splice<BandItem>]]?
        var fields: SpliceFields

        enum CodingKeys: String, CodingKey {
            case reset, items, archived, unplaced, machines, bands, fields
            case bandGroups = "band_groups"
        }
    }

    /// The projection the app holds, kept up to date by applying each answer.
    nonisolated struct KeptProjection {
        var items: [Member] = []
        var archived: [String] = []
        var bandGroups: [Group] = []
        var unplaced: [SidebarDocWorkspaceRef] = []
        var machines: [String: [Node]] = [:]
        var bands: [String: [BandItem]] = [:]
        var fields = Fields()

        nonisolated struct Fields {
            var sections: [ProjectedSection] = []
            var machineSections: [String: String] = [:]
            var machineOrder: [String] = []
            var hostGroups: [String] = []
            var groupSorts: [String: String] = [:]
            var pinnedInGroup: [String] = []
        }

        /// Applies one answer; false when a splice does not fit what is held (the caller asks afresh).
        mutating func apply(_ answer: SpliceAnswer) -> Bool {
            if answer.reset == true { self = KeptProjection() }
            func splice<T>(_ list: inout [T], _ changes: [Splice<T>]?) -> Bool {
                for change in changes ?? [] {
                    guard change.at >= 0, change.remove >= 0, change.at + change.remove <= list.count else { return false }
                    list.replaceSubrange(change.at ..< change.at + change.remove, with: change.insert)
                }
                return true
            }
            guard splice(&items, answer.items), splice(&archived, answer.archived), splice(&bandGroups, answer.bandGroups),
                  splice(&unplaced, answer.unplaced) else { return false }
            for (session, changes) in answer.machines ?? [:] {
                var nodes = machines[session] ?? []
                guard splice(&nodes, changes) else { return false }
                machines[session] = nodes.isEmpty ? nil : nodes
            }
            for (section, changes) in answer.bands ?? [:] {
                var list = bands[section] ?? []
                guard splice(&list, changes) else { return false }
                bands[section] = list
            }
            let new = answer.fields
            if let value = new.sections { fields.sections = value }
            if let value = new.machineSections { fields.machineSections = value }
            if let value = new.machineOrder { fields.machineOrder = value }
            if let value = new.hostGroups { fields.hostGroups = value }
            if let value = new.groupSorts { fields.groupSorts = value }
            if let value = new.pinnedInGroup { fields.pinnedInGroup = value }
            return true
        }

        /// The held projection in the full answer's form (`sidebar_doc::project`).
        var projection: Projection {
            let sections = fields.sections.map { shape -> ProjectedSection in
                guard let section = shape.section else { return shape }
                var band = shape
                band.items = bands[section.id] ?? []
                return band
            }
            return Projection(sections: sections, machines: machines, items: items, machineSections: fields.machineSections,
                              machineOrder: fields.machineOrder, unplaced: unplaced, bandGroups: bandGroups,
                              hostGroups: fields.hostGroups, archived: archived, groupSorts: fields.groupSorts,
                              pinnedInGroup: fields.pinnedInGroup)
        }
    }
}
