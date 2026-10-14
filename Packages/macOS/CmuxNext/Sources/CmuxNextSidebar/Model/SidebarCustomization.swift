public import CmuxNextDesign

extension SidebarWorkspace {
    /// The row with `decoration` applied: its icon (not over a page's favicon), weight, indicator
    /// style and badge (the status line).
    public func decorated(_ decoration: SidebarRowDecoration?) -> SidebarWorkspace {
        guard let decoration else { return self }
        var row = self
        if let icon = decoration.icon.flatMap({ WorkspaceIcon.parse($0) }),
           !(row.icon.map { if case .favicon = $0 { true } else { false } } ?? false) {
            row.icon = icon
        }
        if let weight = decoration.weight { row.titleWeight = weight }
        if let indicator = decoration.indicator { row.activityStyle = indicator }
        if let badge = decoration.badge { row.status = badge }
        return row
    }
}

extension SidebarSection {
    /// The sections with each decorated workspace row's overrides applied (`cmux.sidebar.rows/1`).
    public static func decorated(_ sections: [SidebarSection], _ decorations: [String: SidebarRowDecoration]) -> [SidebarSection] {
        guard !decorations.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.map { node in
                switch node {
                case let .workspace(ws): .workspace(ws.decorated((decorations[ws.id.rawValue] ?? decorations["title:" + ws.title])))
                case let .group(group):
                    .group({ var group = group; group.workspaces = group.workspaces.map { $0.decorated((decorations[$0.id.rawValue] ?? decorations["title:" + $0.title])) }; return group }())
                case .item: node
                }
            }
            return section
        }
    }
}
