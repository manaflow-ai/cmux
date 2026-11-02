import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its rows'
    /// elements, Projects shown, the grouping, a header per computer, minimal mode, the density,
    /// detailed status icons, timestamps, workspace colors and their style, or what group headers show.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
            || previous?.groupsByComputer != groupsByComputer || previous?.minimal != minimal || previous?.density != density
            || previous?.detailedStatusIcons != detailedStatusIcons || previous?.showTimestamps != showTimestamps
            || previous?.showLocalMachine != showLocalMachine || previous?.showColors != showColors
            || previous?.workspaceColorIndicator != workspaceColorIndicator
            || previous?.groupHeaderMemberCount != groupHeaderMemberCount || previous?.groupHeaderUnreadCount != groupHeaderUnreadCount
    }
}
