public import CmuxNextDaemon

extension HomeDock {
    /// Whether tab `id` of the home `workspace` is Home's own and stays in it: a tab of its pinned
    /// column, Home's page or a Chief tab wherever it is, or any tab of a home without a pinned
    /// column (classic Home). The tabs right of the pinned dock are ordinary tabs (Leo 2026-10-19:
    /// "i cant drag from chief's right side tabs to the left sidebar").
    public static func keepsTab(_ id: String, in workspace: WorkspaceModel) -> Bool {
        var pinned = false
        for screen in workspace.screens {
            if screen.panes.contains(where: { $0.tabs.contains { $0.id == id && ($0.page == page || isChiefTab($0)) } }) {
                return true
            }
            for column in screen.columns where column.dock?.isPinned == true {
                pinned = true
                let panes = Set(column.layout.paneIDs)
                if screen.panes.contains(where: { panes.contains($0.handle) && $0.tabs.contains { $0.id == id } }) { return true }
            }
        }
        return !pinned
    }
}
