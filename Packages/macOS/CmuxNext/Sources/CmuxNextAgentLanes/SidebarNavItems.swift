public import CmuxNextActions
import CmuxNextDesign
public import CmuxNextSidebar

/// The sidebar's nav block (`sidebar.nav`): a look's rows of cmux actions at the very top of the
/// sidebar, drawn as plain icon and label rows in the built-in look (no fill at rest, the hover
/// fill), as the Codex app's New chat, Search and Pull requests. Client-only items: never in the
/// layout document, so a look that sets them and is removed leaves the person's sidebar as it was.
extension SidebarTransientItem {
    static let navPrefix = LayoutItemID.transientPrefix + "nav."

    /// One item per row, each titled and drawn with the look's override or the action's own title and
    /// symbol. Unanchored: they draw in the untitled section above Home.
    static func nav(_ rows: [SidebarNavRow]) -> [SidebarTransientItem] {
        guard !rows.isEmpty else { return [] }
        return rows.map { row in
            let descriptor = ActionCatalog.all.first { $0.id.rawValue == row.action }
            let title = row.title ?? descriptor?.title ?? row.action
            let symbol = row.symbol ?? descriptor.map(\.symbol).flatMap { $0.isEmpty ? nil : $0 } ?? "circle"
            return SidebarTransientItem(id: LayoutItemID(navPrefix + row.action), info: SidebarItemInfo(title: title, symbol: symbol))
        }
    }

    /// Runs a nav block item's action, as a person's click; false for any other item.
    public static func activateNav(_ id: LayoutItemID, registry: ActionRegistry) -> Bool {
        guard let action = navAction(id) else { return false }
        _ = registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user))
        return true
    }

    /// The action a nav block item runs, or nil for any other item.
    public static func navAction(_ id: LayoutItemID) -> String? {
        id.rawValue.hasPrefix(navPrefix) ? String(id.rawValue.dropFirst(navPrefix.count)) : nil
    }
}
