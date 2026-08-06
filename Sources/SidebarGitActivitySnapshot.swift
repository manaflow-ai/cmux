import CmuxSettings
import CmuxSidebarGit

/// Immutable settings policy used by sidebar git and control-socket hot paths.
struct SidebarGitActivitySnapshot: Equatable, Sendable {
    let gitMetadataActivity: SidebarGitMetadataActivity
    let pullRequestActivity: SidebarGitMetadataActivity

    static let disabled = Self(
        gitMetadataActivity: .disabled,
        pullRequestActivity: .disabled
    )

    static func load(settings: any SettingsReading) -> Self {
        let sidebar = SidebarCatalogSection()
        let watchGitStatus = settings.value(for: sidebar.watchGitStatus)
        guard watchGitStatus else { return .disabled }

        let hideAllDetails = settings.value(for: sidebar.hideAllDetails)
        let showBranchDirectory = settings.value(for: sidebar.showBranchDirectory)
        let showPullRequests = settings.value(for: sidebar.showPullRequests)
        let gitDetailsVisible = !hideAllDetails &&
            (showBranchDirectory || showPullRequests)
        let pullRequestDetailsVisible = !hideAllDetails && showPullRequests
        return Self(
            gitMetadataActivity: gitDetailsVisible ? .activePolling : .passiveReportsOnly,
            pullRequestActivity: pullRequestDetailsVisible ? .activePolling : .passiveReportsOnly
        )
    }
}
