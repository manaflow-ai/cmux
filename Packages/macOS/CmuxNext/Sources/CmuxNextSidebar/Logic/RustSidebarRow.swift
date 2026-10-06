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
