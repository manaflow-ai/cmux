import CmuxNextActions
import CmuxNextDaemon

/// Home keeps its own tab (Leo 2026-10-09, rapid-switch brief 2): it is never
/// promoted out into a new workspace or a new window, by the tab's menu, the
/// palette, the CLI or a drag. Since the docked Home that tab is the first tab
/// of its pinned column (`pinned-dock-v1`): the tabs right of the dock are
/// ordinary tabs and move out like any other (Leo 2026-10-19: "i cant drag from
/// chief's right side tabs to the left sidebar"). A Home without a pinned
/// column (classic Home) keeps every tab. The App Store is a page item with no
/// tabs, so it has nothing to promote.
enum TabPromotion {
    /// The actions that promote a tab out of its workspace.
    static let actions: [ActionID] = ["palette.moveTabToNewWorkspace", "tab.moveToNewWindow"]

    /// Whether a workspace of `kind` is one that keeps tabs: the merge rule's fixed kinds (Home).
    static func staysPut(kind: String?) -> Bool { WorkspaceMerge.staysPut(kind: kind) }

    /// Whether tab `id` of `workspace` stays in it: a tab of a pinned column of a fixed workspace
    /// (Home's own tab), or any tab of a fixed workspace without a pinned column.
    @MainActor static func staysPut(tab id: String, in workspace: WorkspaceModel?) -> Bool {
        guard let workspace, staysPut(kind: workspace.kind) else { return false }
        var pinned = false
        for screen in workspace.screens {
            for column in screen.columns where column.dock?.isPinned == true {
                pinned = true
                let panes = Set(column.layout.paneIDs)
                if screen.panes.contains(where: { panes.contains($0.handle) && $0.tabs.contains { $0.id == id } }) { return true }
            }
        }
        return !pinned
    }

    /// The tab menu entries a tab that stays put leaves out.
    static func menuRemovals(keepsTab: Bool) -> [ActionID] { keepsTab ? actions : [] }

    /// Why promoting tab `id` is refused; nil when it may.
    @MainActor static func refusal(tab id: String, services: AppServices) -> String? {
        let workspace = services.workspaceID(ofTab: id).flatMap { services.workspace(id: $0) }
        return staysPut(tab: id, in: workspace) ? RefusalStrings.homeKeepsItsTabs : nil
    }
}
