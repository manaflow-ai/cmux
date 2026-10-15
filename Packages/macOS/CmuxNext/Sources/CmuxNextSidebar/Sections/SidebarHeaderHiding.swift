import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its tabs, its rows'
    /// elements, Projects shown, the grouping, a header per computer, minimal mode, or the density.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.showWorkspaceTabs != showWorkspaceTabs || previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
            || previous?.groupsByStatus != groupsByStatus || previous?.statusElbow != statusElbow
            || previous?.groupsByComputer != groupsByComputer || previous?.minimal != minimal || previous?.density != density
    }
}
