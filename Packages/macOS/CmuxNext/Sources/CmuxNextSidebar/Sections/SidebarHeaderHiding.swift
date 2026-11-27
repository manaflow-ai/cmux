import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its rows'
    /// elements, Projects shown, the grouping, a header per computer, the density,
    /// detailed status icons, timestamps (and whether they read relative), workspace colors and their style, what group headers show, how their background draws, the group palette and its gradient, or settling finished chats.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
            || previous?.folderlessUngrouped != folderlessUngrouped
            || previous?.groupsByComputer != groupsByComputer || previous?.density != density
            || previous?.detailedStatusIcons != detailedStatusIcons || previous?.showTimestamps != showTimestamps
            || previous?.relativeTimestamps != relativeTimestamps
            || previous?.showLocalMachine != showLocalMachine || previous?.showColors != showColors
            || previous?.workspaceColorIndicator != workspaceColorIndicator
            || previous?.groupHeaderMemberCount != groupHeaderMemberCount || previous?.groupHeaderUnreadCount != groupHeaderUnreadCount
            || previous?.groupHeaderBackground != groupHeaderBackground || previous?.groupPalette != groupPalette
            || previous?.groupGradient != groupGradient || previous?.settleFinished != settleFinished
            || previous?.showAgentSessions != showAgentSessions
    }
}
