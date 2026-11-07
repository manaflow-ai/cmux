import CmuxSettings
import CmuxSidebar
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
    let showAgentUsage: Bool
    let showAgentModel: Bool
    let showAgentContext: Bool
    let showAgentCost: Bool
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
        showAgentUsage = settings.value(for: sidebar.showAgentUsage)
        showAgentModel = settings.value(for: sidebar.showAgentModel)
        showAgentContext = settings.value(for: sidebar.showAgentContext)
        showAgentCost = settings.value(for: sidebar.showAgentCost)
        showAgentActivity = settings.value(for: sidebar.showAgentActivity)
        showCustomMetadata = settings.value(for: sidebar.showCustomMetadata)
    }

    /// The agent usage components the three per-part settings leave on.
    var agentUsageParts: SidebarAgentUsage.Parts {
        SidebarAgentUsage.Parts(model: showAgentModel, context: showAgentContext, cost: showAgentCost)
    }
}
