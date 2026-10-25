import Foundation

nonisolated struct RustRowKey: Codable {
    var kind: String
    var id: String?
    var section: RustSectionID?
    var workspace: String?

    init(_ value: SidebarRowKey) {
        switch value {
        case let .section(value):
            kind = "section"
            id = nil
            section = RustSectionID(value)
            workspace = nil
        case let .group(group):
            kind = "group"
            id = group.rawValue
            section = nil
            workspace = nil
        case let .workspace(workspaceID):
            kind = "workspace"
            id = workspaceID.rawValue
            section = nil
            workspace = nil
        case let .tab(workspaceID, tab):
            kind = "tab"
            id = tab.rawValue
            section = nil
            workspace = workspaceID.rawValue
        case let .emptySection(value):
            kind = "empty_section"
            id = nil
            section = RustSectionID(value)
            workspace = nil
        case let .folder(value, _):
            // Never sent: `RustRow.resolvable` leaves folder headers out.
            kind = "folder"
            id = nil
            section = RustSectionID(value)
            workspace = nil
        case let .status(status):
            // Never sent either: Group by Status's headers are labels and fold controls only.
            kind = "status"
            id = status.rawValue
            section = nil
            workspace = nil
        case let .doneFold(fold), let .showMore(fold):
            // Never sent: `RustRow.resolvable` leaves "Done (N)" and "Show N more" rows out.
            kind = "folder"
            id = nil
            section = RustSectionID(fold.section)
            workspace = nil
        case let .emptyGroup(group):
            // Never sent: `RustRow.resolvable` leaves an empty group's row out.
            kind = "empty_group"
            id = group.rawValue
            section = nil
            workspace = nil
        case let .item(item), let .block(item):
            // Never sent: `RustRow.resolvable` leaves document rows out.
            kind = "item"
            id = item
            section = nil
            workspace = nil
        }
    }

    var swiftValue: SidebarRowKey? {
        switch kind {
        case "section": return section?.swiftValue.map(SidebarRowKey.section)
        case "group": return id.map(GroupID.init).map(SidebarRowKey.group)
        case "workspace": return id.map(WorkspaceID.init).map(SidebarRowKey.workspace)
        case "tab":
            guard let id, let workspace else { return nil }
            return .tab(WorkspaceID(workspace), TabID(id))
        case "empty_section": return section?.swiftValue.map(SidebarRowKey.emptySection)
        default: return nil
        }
    }

    enum CodingKeys: String, CodingKey { case kind, id, workspace }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
        if kind == "section" || kind == "empty_section" {
            section = try values.decode(RustSectionID.self, forKey: .id)
            id = nil
        } else {
            id = try values.decodeIfPresent(String.self, forKey: .id)
            section = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(workspace, forKey: .workspace)
        if kind == "section" || kind == "empty_section" {
            try values.encode(section, forKey: .id)
        } else {
            try values.encodeIfPresent(id, forKey: .id)
        }
    }
}

nonisolated struct RustRow: Codable {
    /// The rows the drop resolver reads: Group by Folder's headers, "Done (N)"
    /// and "Show N more" rows are labels only (no drop target), so they stay out.
    /// A drag keeps the "Done (N)" rows folded, so a group can end in such a row, or, with the fold open, in a Done
    /// workspace drawn below it with its tab rows: the resolver then reads the group as it would with no fold
    /// (`endingGroup`), and a drop below it can still leave the group.
    static func resolvable(_ rows: [SidebarRow], preservesTabRows: Bool = false) -> [RustRow] {
        var resolvable: [RustRow] = []
        var folded: [String] = []
        for row in rows {
            switch row.key {
            case .doneFold:
                // Closed, it ends its group; open, its Done workspaces (and their tab rows) do.
                if let group = row.group?.rawValue, !folded.contains(group) { folded.append(group) }
                continue
            case .showMore:
                if row.isLastInGroup, let group = row.group?.rawValue, !folded.contains(group) { folded.append(group) }
                continue
            case .folder, .status, .item, .emptyGroup:
                continue
            default:
                if case .custom = row.section { continue } // the older resolver knows Pinned and machines only
                resolvable.append(RustRow(row))
            }
        }
        if !preservesTabRows { for group in folded { endingGroup(group, in: &resolvable) } }
        return resolvable
    }

    /// `group`'s rows, which a fold row ends, read as a group with no fold: its last drawn member is its last row and
    /// takes in its tab rows (the resolver's tab rows never leave a group), so the bottom of it leaves the group; a
    /// group that draws no member reads as folded, so the bottom of its header leaves the group.
    static func endingGroup(_ group: String, in rows: inout [RustRow]) {
        guard let header = rows.lastIndex(where: { $0.key.kind == "group" && $0.key.id == group }) else { return }
        guard let last = rows[(header + 1)...].lastIndex(where: { $0.group == group && $0.key.kind == "workspace" }) else {
            rows[header].isCollapsed = true
            return
        }
        let tabs = rows[(last + 1)...].prefix { $0.key.kind == "tab" && $0.key.workspace == rows[last].key.id }
        if let bottom = tabs.map({ $0.y + $0.height }).max() { rows[last].height = max(rows[last].height, bottom - rows[last].y) }
        rows.removeSubrange((last + 1)..<(last + 1 + tabs.count))
        rows[last].isLastInGroup = true
    }

    var key: RustRowKey
    var y: Double
    var height: Double
    var section: RustSectionID
    var group: String?
    var workspace: String?
    var siblingIndex: Int
    var parentIndex: Int?
    var isLastInGroup: Bool
    var isCollapsed: Bool
    var childCount: Int

    enum CodingKeys: String, CodingKey {
        case key, y, height, section, group, workspace
        case siblingIndex = "sibling_index"
        case parentIndex = "parent_index"
        case isLastInGroup = "is_last_in_group"
        case isCollapsed = "is_collapsed"
        case childCount = "child_count"
    }

    init(_ row: SidebarRow) {
        key = RustRowKey(row.key)
        y = Double(row.y)
        height = Double(row.height)
        section = RustSectionID(row.section)
        group = row.group?.rawValue
        workspace = row.workspace?.rawValue
        siblingIndex = row.siblingIndex
        parentIndex = row.parentIndex
        isLastInGroup = row.isLastInGroup
        isCollapsed = row.isCollapsed
        childCount = row.childCount
    }
}
