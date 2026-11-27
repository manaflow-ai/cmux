public import AppKit

/// design/menus.md, "Menus spend no width or height on nothing": a menu whose rows carry icons gives every
/// row its icon, and a menu with none reserves no icon column. AppKit and the glass menu
/// (`GlassMenuListView`) open the icon column when any row has an image, so a row without one in such
/// a menu starts its text an empty icon slot in (Leo 2026-11-22, the browser More menu's Show in
/// Toolbar: "some bullshit left indent that indents for literally nothing. either get rid of the indent
/// or give it an icon").
public enum MenuIconColumn {
    /// The rows of `menu` and its submenus that have no icon in a menu where another row has one, each as
    /// its path (`More > Show in Toolbar`). Separators, section headers and rows drawn by a custom view
    /// are not in the column.
    @MainActor public static func rowsWithoutIcon(in menu: NSMenu, path: String = "") -> [String] {
        let rows = menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader && $0.view == nil }
        let hasColumn = rows.contains { $0.image != nil }
        var found: [String] = []
        for row in rows {
            let name = path.isEmpty ? row.title : "\(path) > \(row.title)"
            if hasColumn, row.image == nil { found.append(name) }
            if let submenu = row.submenu { found += rowsWithoutIcon(in: submenu, path: name) }
        }
        return found
    }
}
