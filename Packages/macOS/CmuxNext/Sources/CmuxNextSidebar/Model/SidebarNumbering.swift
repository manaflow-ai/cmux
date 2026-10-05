import Foundation

/// The one numbering for Cmd+1…9 (R119): Home is 1, then the selectable
/// workspaces in sidebar order; 9 is the last. Anything that shows or acts on
/// these numbers (the action, a future number hint on rows) reads this.
public nonisolated enum SidebarNumbering {
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
