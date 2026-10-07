import CmuxNextDesign

extension Set where Element == LayoutSectionID {
    /// The sections their headers' menus hide: Recents while `sidebar.showRecents` is off.
    @MainActor static func hiddenByHeaders(_ preferences: SidebarSectionsPreferences = DesignSettings.shared.sidebarSections) -> Self {
        preferences.showRecents ? [] : [SidebarLayoutDocument.recentsSectionID]
    }
}

extension SidebarSectionsPreferences {
    /// Whether the workspace list draws differently than under `previous`: its tabs, its rows'
    /// elements, Projects shown, or the grouping.
    func changesList(from previous: SidebarSectionsPreferences?) -> Bool {
        previous?.showWorkspaceTabs != showWorkspaceTabs || previous?.workspaceRow != workspaceRow
            || previous?.showProjects != showProjects || previous?.groupBy != groupBy
    }
}
