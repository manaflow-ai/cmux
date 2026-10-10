extension SidebarModel {
    /// This sidebar's destinations in shown order (``SidebarItemOrder``): the
    /// top region's visible items (hidden, missing and suppressed apps' items
    /// skipped), then the list's selectable rows in drawn order (the sidebar's
    /// own row layout, so collapsed sections and rows the filter hides are not
    /// stops). A collapsed group is one stop; an empty one is none.
    public var itemOrder: SidebarItemOrder {
        let top = layout.sections(in: .top, room: activeProfileID?.rawValue).flatMap(\.items).filter { item in
            let info = itemInfo[item.id]
            return info?.isHidden != true && info?.isMissing != true && !suppressedApps.contains(item.owningAppID ?? "")
        }
        var options = SidebarLayoutOptions()
        options.filterMatches = filterMatches
        options.groupsByFolder = groupsByFolder
        let selectable = Set(selectableWorkspaces.map(\.id))
        var rows: [SidebarItem] = []
        var stops: [WorkspaceID: SidebarItem] = [:]
        for row in SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows {
            switch row.key {
            case let .workspace(id) where selectable.contains(id):
                rows.append(.workspace(id))
            case let .group(id):
                guard let group = group(id), group.isCollapsed else { continue }
                let members = group.workspaces.map(\.id).filter(selectable.contains)
                guard !members.isEmpty else { continue }
                rows.append(.group(id))
                for member in members { stops[member] = .group(id) }
            default:
                continue
            }
        }
        return SidebarItemOrder(topItems: top.map { .topItem($0.id) }, rows: rows, stops: stops)
    }
}
