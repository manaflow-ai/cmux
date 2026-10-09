import CmuxNextActions

/// Home keeps its tabs (Leo 2026-10-09, rapid-switch brief 2): none is
/// promoted out of it into a new workspace or a new window, by the tab's
/// menu, the palette, the CLI or a drag. The App Store is a page item with
/// no tabs, so it has nothing to promote.
enum TabPromotion {
    /// The actions that promote a tab out of its workspace.
    static let actions: [ActionID] = ["palette.moveTabToNewWorkspace", "tab.moveToNewWindow"]

    /// Whether a tab of a workspace of `kind` stays in it: the merge rule's
    /// fixed kinds (Home).
    static func staysPut(kind: String?) -> Bool { TabDragSession.staysPut(kind: kind) }

    /// The tab menu entries a tab of a workspace of `kind` leaves out.
    static func menuRemovals(kind: String?) -> [ActionID] { staysPut(kind: kind) ? actions : [] }

    /// Why promoting a tab of a workspace of `kind` is refused; nil when it may.
    static func refusal(kind: String?) -> String? { staysPut(kind: kind) ? RefusalStrings.homeKeepsItsTabs : nil }

    /// Why promoting tab `id` is refused, from its workspace's kind.
    @MainActor static func refusal(tab id: String, services: AppServices) -> String? {
        refusal(kind: services.workspaceID(ofTab: id).flatMap { services.workspace(id: $0) }?.kind)
    }
}
