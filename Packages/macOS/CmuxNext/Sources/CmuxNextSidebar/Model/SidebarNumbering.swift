import Foundation

/// The one numbering for Cmd+1…9 (R119): Home is 1, then the workspace rows
/// the user sees, top to bottom; 9 is the last visible. Anything that shows or
/// acts on these numbers (the action, a future number hint on rows) reads this.
public nonisolated struct SidebarNumbering: Hashable, Sendable {
    /// The numbered ids in order: Home first (when it exists), then the
    /// workspaces without Home.
    public let order: [String]

    public init(home: String?, workspaces: [String]) {
        guard let home else {
            order = workspaces
            return
        }
        order = [home] + workspaces.filter { $0 != home }
    }

    /// The id number `number` (1…9) selects: 9 and numbers past the end
    /// select the last; nil for a number below 1 or an empty list.
    public func pick(_ number: Int) -> String? {
        guard number >= 1, let last = order.last else { return nil }
        return number >= 9 ? last : order[min(number, order.count) - 1]
    }
}

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
