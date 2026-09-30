import Foundation

/// Which browser profile a new tab gets and when the UI shows it
/// (plans/cmux-next/data-model.md section 5). The result is stored on the
/// tab at creation and never follows a later default change, so a live page
/// never changes cookie jar.
public nonisolated enum BrowserProfileCascade {
    /// The first known id of: an explicit choice, the workspace's browser
    /// profile, its room's; else `default`. There is no window level: a
    /// window's browser profile is its room's.
    public static func resolve(explicit: String?, workspace: String?, room: String?, known: (String) -> Bool) -> String {
        BrowserProfileRecord.defaultID // stub
    }

    /// A tab shows a profile dot when its profile differs from the one new
    /// tabs of its workspace get (a record without an id is `default`).
    public static func showsTabBadge(tabProfile: String?, workspaceEffective: String) -> Bool {
        false // stub
    }

    /// The omnibar shows the tab's profile once more than one exists.
    public static func showsOmnibarBadge(profileCount: Int) -> Bool { false } // stub
}
