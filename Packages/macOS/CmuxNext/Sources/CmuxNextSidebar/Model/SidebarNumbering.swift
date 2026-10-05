import Foundation

/// The one numbering for Cmd+1…9 (R119): Home is 1, then the workspace rows
/// the user sees, top to bottom; 9 is the last visible. Anything that shows or acts on
/// these numbers (the action, a future number hint on rows) reads this.
public nonisolated enum SidebarNumbering {
    /// The selectable workspace rows the sidebar draws, in drawn order: the
    /// sidebar's own row layout, so collapsed sections, collapsed groups and
    /// rows the filter hides get no number.
    @MainActor
    public static func visibleWorkspaces(_ model: SidebarModel) -> [String] {
        var options = SidebarLayoutOptions()
        options.filterMatches = model.filterMatches
        let selectable = Set(model.selectableWorkspaces.map(\.id))
        return SidebarLayout.make(sections: model.sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .workspace(id) = row.key, selectable.contains(id) { id.rawValue } else { nil }
        }
    }

    /// Home first (when it exists), then `workspaces` without Home.
    public static func order(home: String?, workspaces: [String]) -> [String] {
        guard let home else { return workspaces }
        return [home] + workspaces.filter { $0 != home }
    }

    /// The id number `number` (1…9) selects: 9 and numbers past the end
    /// select the last; nil for a number below 1 or an empty list.
    public static func pick(_ number: Int, home: String?, workspaces: [String]) -> String? {
        let all = order(home: home, workspaces: workspaces)
        guard number >= 1, let last = all.last else { return nil }
        return number >= 9 ? last : all[min(number, all.count) - 1]
    }
}
