import Foundation

/// The one numbering for Cmd+1…9 (R119, TOP-SECTION-ITEMS-ARE-PAGES): the
/// first top-section item (Home by default, which opens its page) is 1, then
/// the workspace rows the user sees, top to bottom; 9 is the last. Anything
/// that shows or acts on these numbers (the action, a future number hint on
/// rows) reads this.
public nonisolated struct SidebarNumbering: Hashable, Sendable {
    /// What a number selects.
    public enum Target: Hashable, Sendable {
        /// A top-section item, run as a click does.
        case topItem(LayoutItemID)
        /// A workspace row.
        case workspace(String)
    }

    /// The numbered targets in order: the first top item (when the top
    /// section has one), then the workspaces.
    public let order: [Target]

    public init(firstTopItem: LayoutItemID?, workspaces: [String]) {
        order = workspaces.map(Target.workspace) // RED stub: the top item is not numbered yet
    }

    /// The target number `number` (1…9) selects: 9 and numbers past the end
    /// select the last; nil for a number below 1 or an empty list.
    public func pick(_ number: Int) -> Target? {
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
