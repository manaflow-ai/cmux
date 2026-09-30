public import Foundation

/// GitHub pull-request badge polling for workspace panels: poll deadlines
/// with jitter, batched refreshes through the `CmuxGit` probe pipeline,
/// transient-failure staleness, and command-hint reconciliation.
///
/// Implemented by ``PullRequestPollService``; consumed by the host and by
/// ``SidebarGitMetadataService`` (a local probe that finds a branch schedules
/// a PR refresh here). Method names match the legacy `TabManager` methods
/// one-for-one so the lift stays reviewable against the original.
@MainActor
public protocol PullRequestProbing: AnyObject {
    /// Wires the host seam and captures the initial polling-setting value.
    /// Must be called once, before any scheduling entry point.
    func attach(host: any SidebarGitHosting)
    /// Requests a refresh for one panel (marks its poll deadline immediate,
    /// or queues a rerun if a refresh is already in flight).
    func scheduleWorkspacePullRequestRefresh(workspaceId: UUID, panelId: UUID, reason: String)
    /// Runs one refresh pass over every tracked panel whose deadline is due.
    func refreshTrackedWorkspacePullRequestsIfNeeded(reason: String)
    /// Reacts to the pull-request polling setting toggling.
    func sidebarPullRequestPollingSettingsDidChange()
    /// Applies a `gh pr merge/close/reopen` command hint optimistically and
    /// schedules a verifying refresh.
    func handleWorkspacePullRequestCommandHint(
        workspaceId: UUID,
        panelId: UUID,
        action: String,
        target: String?
    )
    /// Drops poll tracking for one panel.
    func clearWorkspacePullRequestTracking(workspaceId: UUID, panelId: UUID)
    /// Drops poll tracking for one panel and clears its badge.
    func clearWorkspacePullRequestMetadata(workspaceId: UUID, panelId: UUID)
    /// Drops poll tracking for a whole workspace.
    func clearWorkspacePullRequestTracking(workspaceId: UUID)
    /// Cancels any in-flight refresh and drops all tracking and caches.
    func resetWorkspacePullRequestRefreshState()
    /// Panel ids with any PR poll tracking state (test seam).
    func workspacePullRequestTrackedPanelIds(workspaceId: UUID) -> Set<UUID>
}
