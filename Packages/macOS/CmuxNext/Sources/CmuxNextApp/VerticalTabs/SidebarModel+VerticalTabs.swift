import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import Observation

extension SidebarModel {
    /// One list for a workspace's tabs (Leo 2026-10-20): a workspace showing vertical tabs lists them beside
    /// its panes, so this sidebar stops listing them under its row (`sidebar.showWorkspaceTabs`). Follows
    /// the per-workspace choices and `tabs.verticalTabs` for as long as the model lives.
    func followingVerticalTabs(_ store: WorkspaceVerticalTabs = .shared) -> SidebarModel {
        Task { @MainActor [weak self] in
            for await tabs in ObservationStream({ SidebarInWorkspaceTabs(store, allWorkspaces: DesignSettings.shared.verticalTabs) }) {
                guard let self else { return }
                if inWorkspaceTabs != tabs { inWorkspaceTabs = tabs }
            }
        }
        return self
    }
}

extension SidebarInWorkspaceTabs {
    init(_ store: WorkspaceVerticalTabs, allWorkspaces: Bool) {
        self.init(allWorkspaces: allWorkspaces,
                  choices: Dictionary(uniqueKeysWithValues: store.choices.map { (CmuxNextSidebar.WorkspaceID($0.key), $0.value) }))
    }
}
