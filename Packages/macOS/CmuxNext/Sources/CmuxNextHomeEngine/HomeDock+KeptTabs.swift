public import CmuxNextDaemon

extension HomeDock {
    /// Whether tab `id` of the home `workspace` is Home's own and stays in it: Home's page or a Chief
    /// tab wherever it is, or any tab of a home without a pinned column (classic Home). Every other
    /// tab is an ordinary tab: the tabs right of the pinned dock (Leo 2026-10-19: "i cant drag from
    /// chief's right side tabs to the left sidebar") and a tab dragged into the dock, which drags out
    /// again (Leo 2026-10-21: "JUST MAKE THE TAB THING SHOW UP ON THE MAIN PANE TOO").
    public static func keepsTab(_ id: String, in workspace: WorkspaceModel) -> Bool {
        var pinned = false
        for screen in workspace.screens {
            if screen.panes.contains(where: { $0.tabs.contains { $0.id == id && ($0.page == page || isChiefTab($0)) } }) {
                return true
            }
            pinned = pinned || screen.columns.contains { $0.dock?.isPinned == true }
        }
        return !pinned
    }
}
