import CmuxNextDesign
import Foundation

extension WindowRegistry {
    /// The workspace a window should show after its membership changed from
    /// `previous` to `members`. The selection belongs to the window's
    /// `WindowState`; this only repairs it:
    /// - `preferred` (workspaces just moved in by the user) wins,
    /// - a selection that is still a member stays,
    /// - a selection that left falls to its next surviving neighbor in the
    ///   old order, then the previous one, then the first member
    ///   (`FocusAfterClose.workspace`, close-focus.md),
    /// - no members: nil (only for a window being removed; a registered
    ///   window always has one).
    static func repairedSelection(current: String?, previous: [String], members: [String], preferred: [String] = []) -> String? {
        if let pick = preferred.first(where: members.contains) { return pick }
        return FocusAfterClose.workspace(shown: current, old: previous, surviving: members)
    }

    /// A window's members (`ids`, in the order they joined it) in its sidebar's row order
    /// (`rows`), the order a close's "next row" means. Members the sidebar does not list
    /// keep their order after the rows. When the sidebar no longer lists `current` (it
    /// already dropped the closed row), `ids` as they are: the rows cannot place it.
    static func sidebarOrdered(_ ids: [String], rows: [String], current: String?) -> [String] {
        guard let current, rows.contains(current) else { return ids }
        let members = Set(ids), listed = Set(rows)
        return rows.filter(members.contains) + ids.filter { !listed.contains($0) }
    }
}
