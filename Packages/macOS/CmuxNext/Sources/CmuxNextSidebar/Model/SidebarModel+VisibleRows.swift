import Foundation

extension SidebarModel {
    /// The selectable workspace rows the sidebar draws, in drawn order: the
    /// sidebar's own row layout, so collapsed sections, collapsed groups and
    /// rows the filter hides get no number.
    public var visibleWorkspaceIDs: [String] {
        var options = SidebarLayoutOptions()
        options.filterMatches = filterMatches
        let selectable = Set(selectableWorkspaces.map(\.id))
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .workspace(id) = row.key, selectable.contains(id) { id.rawValue } else { nil }
        }
    }
}
