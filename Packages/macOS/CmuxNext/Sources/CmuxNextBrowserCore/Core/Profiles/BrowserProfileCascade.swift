package import Foundation

/// Which browser profile a new tab gets and when the UI shows it
/// (plans/cmux-next/data-model.md section 5). The result is stored on the
/// tab at creation and never follows a later default change, so a live page
/// never changes cookie jar.
public nonisolated enum BrowserProfileCascade {
    /// The first known id of: an explicit choice, the workspace's browser
    /// profile, its room's; else `default`. There is no window level: a
    /// window's browser profile is its room's.
    public static func resolve(explicit: String?, workspace: String?, room: String?, known: (String) -> Bool) -> String {
        for candidate in [explicit, workspace, room] {
            if let candidate, !candidate.isEmpty, known(candidate) { return candidate }
        }
        return BrowserProfileRecord.defaultID
    }

    /// Why a tab has its profile, as far as today's defaults say (the profile menu's header line). A tab
    /// keeps the profile it was made with, so this reads the tab's profile against the defaults now.
    public enum Source: Hashable, Sendable {
        /// The workspace's browser profile.
        case workspace
        /// The space's browser profile.
        case space
        /// The built-in default, with no default naming another.
        case builtIn
        /// None of the defaults: chosen for this tab (or a default changed after the tab was made).
        case tab
    }

    /// The source of `tabProfile` (nil = `default`): the workspace's default when it names it, else
    /// the space's when no workspace default stands before it, else the built-in default, else the tab.
    public static func source(tabProfile: String?, workspace: String?, room: String?, known: (String) -> Bool) -> Source {
        let id = tabProfile ?? BrowserProfileRecord.defaultID
        func usable(_ candidate: String?) -> String? { candidate.flatMap { !$0.isEmpty && known($0) ? $0 : nil } }
        if let workspace = usable(workspace) { return workspace == id ? .workspace : .tab }
        if let room = usable(room) { return room == id ? .space : .tab }
        return id == BrowserProfileRecord.defaultID ? .builtIn : .tab
    }

    /// A tab shows a profile dot when its profile differs from the one new
    /// tabs of its workspace get (a record without an id is `default`).
    public static func showsTabBadge(tabProfile: String?, workspaceEffective: String) -> Bool {
        (tabProfile ?? BrowserProfileRecord.defaultID) != workspaceEffective
    }
}
