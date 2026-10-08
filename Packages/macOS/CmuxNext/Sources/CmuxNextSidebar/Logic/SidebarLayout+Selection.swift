extension SidebarLayout {
    /// The row that paints the selection fill for `selected`: its workspace or
    /// group row, or the collapsed group header that stands for a workspace
    /// inside it; nil for a top item or a row this layout does not show. The
    /// fill changes in place on that row, never travels
    /// (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION).
    func selectedRowKey(for selected: SidebarItem?, in sections: [SidebarSection]) -> SidebarRowKey? {
        switch selected {
        case let .group(id)?:
            return row(for: .group(id)) == nil ? nil : .group(id)
        case let .workspace(id)?:
            if row(for: .workspace(id)) != nil { return .workspace(id) }
            let group = sections.lazy.flatMap(\.nodes).compactMap { node -> GroupID? in
                if case let .group(group) = node, group.isCollapsed, group.workspaces.contains(where: { $0.id == id }) { group.id } else { nil }
            }.first
            return group.flatMap { row(for: .group($0)) == nil ? nil : .group($0) }
        case .topItem?, nil:
            return nil
        }
    }
}
