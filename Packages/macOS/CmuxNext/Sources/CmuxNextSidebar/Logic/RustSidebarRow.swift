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
    static func resolvable(_ rows: [SidebarRow]) -> [RustRow] {
        rows.compactMap { row in
            if case .folder = row.key { return nil }
            if case .status = row.key { return nil }
            if case .doneFold = row.key { return nil }
            if case .showMore = row.key { return nil }
            if case .item = row.key { return nil }
            // An empty group's row: the pointer over it falls on the open header's lower part, a drop into the group.
            if case .emptyGroup = row.key { return nil }
            if case .custom = row.section { return nil } // the older resolver knows Pinned and machines only
            return RustRow(row)
        }
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
