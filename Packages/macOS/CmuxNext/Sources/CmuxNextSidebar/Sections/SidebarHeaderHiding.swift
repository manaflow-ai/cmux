import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its tabs, its rows'
    /// elements, Projects shown, the grouping, a header per computer, minimal mode, the density,
    /// or detailed status icons.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.showWorkspaceTabs != showWorkspaceTabs || previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
            || previous?.groupsByComputer != groupsByComputer || previous?.minimal != minimal || previous?.density != density
            || previous?.detailedStatusIcons != detailedStatusIcons
    }
}
