import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its tabs, its rows'
    /// elements, Projects shown, or the grouping.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.showWorkspaceTabs != showWorkspaceTabs || previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
    }
}
