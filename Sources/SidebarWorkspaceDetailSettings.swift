import CmuxSettings
import Foundation

/// Catalog-backed workspace-detail preferences shared by both sidebar row models.
///
/// Detail toggles resolve through `sidebar.density`, so an unset toggle follows
/// the density preset and an explicitly set toggle keeps its own value.
struct SidebarWorkspaceDetailSettings: Equatable {
    let showBranchDirectory: Bool
    let showPullRequests: Bool
    let watchGitStatus: Bool
    let showSSH: Bool
    let showPorts: Bool
    let showLog: Bool
    let showProgress: Bool
    let showAgentActivity: Bool
    let showCustomMetadata: Bool

    init(defaults: UserDefaults) {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let sidebar = SidebarCatalogSection()
        showBranchDirectory = settings.sidebarDetailValue(for: sidebar.showBranchDirectory)
        showPullRequests = settings.sidebarDetailValue(for: sidebar.showPullRequests)
        watchGitStatus = settings.value(for: sidebar.watchGitStatus)
        showSSH = settings.value(for: sidebar.showSSH)
        showPorts = settings.sidebarDetailValue(for: sidebar.showPorts)
        showLog = settings.sidebarDetailValue(for: sidebar.showLog)
        showProgress = settings.sidebarDetailValue(for: sidebar.showProgress)
        showAgentActivity = settings.value(for: sidebar.showAgentActivity)
        showCustomMetadata = settings.sidebarDetailValue(for: sidebar.showCustomMetadata)
    }
}
