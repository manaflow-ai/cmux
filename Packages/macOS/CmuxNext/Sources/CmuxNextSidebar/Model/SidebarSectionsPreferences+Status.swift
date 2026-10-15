import CmuxNextDesign

extension SidebarSectionsPreferences {
    /// These preferences with Group by Status's Debug toggles laid over them. Read where the
    /// sidebar observes its preferences, so flipping a toggle re-groups the open sidebar.
    func withStatusDebugToggles() -> SidebarSectionsPreferences {
        var preferences = self
        preferences.groupsByStatus = SidebarTunables.groupByStatus.value
        preferences.statusElbow = preferences.groupsByStatus && SidebarTunables.statusElbow.value
        return preferences
    }
}
