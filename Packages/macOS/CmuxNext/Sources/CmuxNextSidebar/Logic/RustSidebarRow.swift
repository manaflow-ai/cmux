import Foundation

nonisolated struct RustRowKey: Codable {
    var kind: String
    var id: String?
    var section: RustSectionID?

    init(_ value: SidebarRowKey) {
        switch value {
        case let .section(value):
            kind = "section"
            id = nil
            section = RustSectionID(value)
        case let .group(group):
            kind = "group"
            id = group.rawValue
            section = nil
        case let .workspace(workspaceID):
            kind = "workspace"
            id = workspaceID.rawValue
            section = nil
        case let .emptySection(value):
            kind = "empty_section"
            id = nil
            section = RustSectionID(value)
        case let .folder(value, _):
            // Never sent: `RustRow.resolvable` leaves folder headers out.
            kind = "folder"
            id = nil
            section = RustSectionID(value)
        case let .status(status):
            // Never sent either: Group by Status's headers are labels and fold controls only.
            kind = "status"
            id = status.rawValue
            section = nil
        case let .doneFold(fold), let .showMore(fold):
            // Never sent: `RustRow.resolvable` leaves "Done (N)" and "Show N more" rows out.
            kind = "folder"
            id = nil
            section = RustSectionID(fold.section)
        case let .emptyGroup(group):
            // Never sent: `RustRow.resolvable` leaves an empty group's row out.
            kind = "empty_group"
            id = group.rawValue
            section = nil
        case let .item(item), let .block(item):
            // Never sent: `RustRow.resolvable` leaves document rows out.
            kind = "item"
            id = item
            section = nil
        }
    }

    var swiftValue: SidebarRowKey? {
        switch kind {
        case "section": return section?.swiftValue.map(SidebarRowKey.section)
        case "group": return id.map(GroupID.init).map(SidebarRowKey.group)
        case "workspace": return id.map(WorkspaceID.init).map(SidebarRowKey.workspace)
        case "empty_section": return section?.swiftValue.map(SidebarRowKey.emptySection)
        default: return nil
        }
    }

    enum CodingKeys: String, CodingKey { case kind, id }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
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
    /// workspace drawn below it: the resolver then reads the group as it would with no fold (`endingGroup`), and a
    /// drop below it can still leave the group. A tab drop (`keepsFoldRows`) reads the groups as drawn.
    ///
    /// `soleRowsAsHeaders`: a group's one row (`SidebarRow.standsForGroup`) sits in its header's slot, so a workspace or
    /// group drag reads it as the group's open header: its upper edge drops before the group, its body into the group.
    /// A tab drop keeps it a workspace row, so a tab still drops into that workspace.
    static func resolvable(_ rows: [SidebarRow], keepsFoldRows: Bool = false, soleRowsAsHeaders: Bool = true) -> [RustRow] {
        var resolvable: [RustRow] = []
        var folded: [String] = []
        var itemTops: [String: Double] = [:] // per group, the lowest link, tab or app item row still shown (no drop target, but open)
        var nesting: [(group: String, depth: Int, section: SectionID)] = [] // the group headers above this row, outermost first
        var parents: Set<String> = [] // groups that draw a subgroup (only an open group does)
        for row in rows {
            // A group's one row stands in its header's place, one level in: its parent still draws a subgroup.
            let header = row.standsForGroup ? row.depth - 1 : row.depth
            if case .group = row.key, let group = row.group?.rawValue {
                while let top = nesting.last, top.depth >= header || top.section != row.section { nesting.removeLast() }
                if let parent = nesting.last { parents.insert(parent.group) }
                nesting.append((group, header, row.section))
            } else if row.standsForGroup {
                while let top = nesting.last, top.depth >= header || top.section != row.section { nesting.removeLast() }
                if let parent = nesting.last { parents.insert(parent.group) }
            }
            switch row.key {
            case .doneFold:
                // Closed, it ends its group; open, its Done workspaces do.
                if let group = row.group?.rawValue, !folded.contains(group) { folded.append(group) }
                continue
            case .showMore:
                if row.isLastInGroup, let group = row.group?.rawValue, !folded.contains(group) { folded.append(group) }
                continue
            case .item:
                if let group = row.group?.rawValue { itemTops[group] = max(itemTops[group] ?? -.infinity, Double(row.y)) }
                continue
            case .folder, .status, .emptyGroup:
                continue
            default:
                if case .custom = row.section { continue } // the older resolver knows Pinned and machines only
                if soleRowsAsHeaders, let header = row.standingHeader {
                    resolvable.append(RustRow(header))
                    continue
                }
                resolvable.append(RustRow(row))
            }
        }
        if !keepsFoldRows {
            for group in folded { endingGroup(group, in: &resolvable, lastItemY: itemTops[group], drawsSubgroup: parents.contains(group)) }
        }
        return resolvable
    }

    /// `group`'s rows, which a fold row ends, read as a group with no fold: its last drawn member is its last row, so
    /// the bottom of it leaves the group; a
    /// group that draws no member reads as folded, so the bottom of its header leaves the group, unless it still draws
    /// item rows (`lastItemY`, the top of its lowest one) or a subgroup (`drawsSubgroup`): it is open, and a drop on its
    /// header goes into it as with no fold. An item row drawn below the last member ends the group instead, so that
    /// member keeps its place in it.
    static func endingGroup(_ group: String, in rows: inout [RustRow], lastItemY: Double? = nil, drawsSubgroup: Bool = false) {
        guard let header = rows.lastIndex(where: { $0.key.kind == "group" && $0.key.id == group }) else { return }
        guard let last = rows[(header + 1)...].lastIndex(where: { $0.group == group && $0.key.kind == "workspace" }) else {
            if lastItemY == nil, !drawsSubgroup { rows[header].isCollapsed = true }
            return
        }
        if let lastItemY, lastItemY >= rows[last].y + rows[last].height { return }
        rows[last].isLastInGroup = true
    }

    var key: RustRowKey
    var y: Double
    var height: Double
    var section: RustSectionID
    var group: String?
    var siblingIndex: Int
    var parentIndex: Int?
    var isLastInGroup: Bool
    var isCollapsed: Bool
    var childCount: Int

    enum CodingKeys: String, CodingKey {
        case key, y, height, section, group
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
        siblingIndex = row.siblingIndex
        parentIndex = row.parentIndex
        isLastInGroup = row.isLastInGroup
        isCollapsed = row.isCollapsed
        childCount = row.childCount
    }
}
