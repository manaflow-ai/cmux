#if os(iOS)
import CmuxMobileShellModel

extension WorkspaceShellView {
    /// Resolves the one workspace detail route currently visible in the shell.
    /// Simulator stream teardown observes this owner-level value, never child view
    /// appearance, so recovery remounts preserve selection while real navigation
    /// away stops the old workspace.
    static func visibleSimulatorStreamWorkspaceID(
        selectedPrimaryTab: MobilePrimaryTab,
        searchScope: MobilePrimarySearchScope,
        usesCompactStack: Bool,
        selectedWorkspaceID: MobileWorkspacePreview.ID?,
        compactNavigationPath: [MobileWorkspacePreview.ID],
        notificationNavigationPath: [MobileWorkspacePreview.ID],
        workspaceSearchNavigationPath: [MobileWorkspacePreview.ID],
        notificationSearchNavigationPath: [MobileWorkspacePreview.ID]
    ) -> MobileWorkspacePreview.ID? {
        switch selectedPrimaryTab {
        case .workspaces:
            usesCompactStack ? compactNavigationPath.last : selectedWorkspaceID
        case .notifications:
            notificationNavigationPath.last
        case .search:
            switch searchScope {
            case .workspaces:
                workspaceSearchNavigationPath.last
            case .notifications:
                notificationSearchNavigationPath.last
            }
        }
    }
}
#endif
