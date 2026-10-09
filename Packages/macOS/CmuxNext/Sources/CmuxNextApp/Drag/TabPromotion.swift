import CmuxNextActions

/// Home keeps its tabs (Leo 2026-10-09, rapid-switch brief 2): none is
/// promoted out of it into a new workspace or a new window, by the tab's
/// menu, the palette, the CLI or a drag. The App Store is a page item with
/// no tabs, so it has nothing to promote.
enum TabPromotion {
    /// The actions that promote a tab out of its workspace.
    static let actions: [ActionID] = ["palette.moveTabToNewWorkspace", "tab.moveToNewWindow"]

    /// Whether a tab of a workspace of `kind` stays in it.
    static func staysPut(kind: String?) -> Bool { false }

    /// The tab menu entries a tab of a workspace of `kind` leaves out.
    static func menuRemovals(kind: String?) -> [ActionID] { [] }

    /// Why promoting a tab of a workspace of `kind` is refused; nil when it may.
    static func refusal(kind: String?) -> String? { nil }
}
