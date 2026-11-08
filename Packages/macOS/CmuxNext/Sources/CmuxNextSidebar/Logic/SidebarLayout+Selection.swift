extension SidebarLayout {
    /// The row that stands for `selected`: its workspace or group row, or the
    /// collapsed group header that holds a workspace inside it (which paints
    /// no fill, cx-fo2t); nil for a top item or a row this layout does not
    /// show. The fill changes in place on that row, never travels
    /// (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION).
    func selectedRowKey(for selected: SidebarItem?, in sections: [SidebarSection]) -> SidebarRowKey? {
        switch selected {
        case let .group(id)?:
            return groupRow(id)?.key
        case let .workspace(id)?:
            if row(for: .workspace(id)) != nil { return .workspace(id) }
            let group = sections.lazy.flatMap(\.nodes).compactMap { node -> GroupID? in
                if case let .group(group) = node, group.isCollapsed, group.workspaces.contains(where: { $0.id == id }) { group.id } else { nil }
            }.first
            return group.flatMap { groupRow($0)?.key }
        case let .topItem(id)?:
            // A document item the list draws as a row (a link in a machine list).
            return row(for: .item(id.rawValue)) == nil ? nil : .item(id.rawValue)
        case nil:
            return nil
        }
    }
}
