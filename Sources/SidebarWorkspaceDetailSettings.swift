import CmuxSettings
import Foundation

/// Catalog-backed workspace-detail preferences shared by both sidebar row models.
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
        showBranchDirectory = settings.value(for: sidebar.showBranchDirectory)
        showPullRequests = settings.value(for: sidebar.showPullRequests)
        watchGitStatus = settings.value(for: sidebar.watchGitStatus)
        showSSH = settings.value(for: sidebar.showSSH)
        showPorts = settings.value(for: sidebar.showPorts)
        showLog = settings.value(for: sidebar.showLog)
        showProgress = settings.value(for: sidebar.showProgress)
        showAgentActivity = settings.value(for: sidebar.showAgentActivity)
        showCustomMetadata = settings.value(for: sidebar.showCustomMetadata)
    }
}
