import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its tabs, its rows'
    /// elements, Projects shown, the grouping, or a header per computer.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.showWorkspaceTabs != showWorkspaceTabs || previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
            || previous?.groupsByComputer != groupsByComputer
    }
}
