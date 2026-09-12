public import Foundation

/// The window-side seam the sidebar git services drive: snapshot reads of
/// workspace/panel state, synchronous projection writes of branch and
/// pull-request badges / repository links, and the environment toggles the
/// schedulers honor.
///
/// **Why a synchronous two-way protocol and not an AsyncStream of results.**
/// Every state transition in the legacy subsystem is one MainActor turn that
/// interleaves reads (does the panel still exist, is its directory still the
/// probed one) with writes (badge updates, probe bookkeeping) and immediate
/// follow-up scheduling. Pushing the writes through a stream would open a
/// suspension window between a probe completing and its projection landing,
/// during which user-driven mutations (directory change, panel close) could
/// interleave — an observable behavior change to badge transitions. The
/// services therefore stay `@MainActor` and call the host synchronously,
/// preserving the legacy interleavings exactly; the host (the per-window
/// `TabManager`) is the single implementer.
///
/// All identifier pairs are (workspace id, panel id); reads return `nil` or
/// empty values when the workspace/panel is gone, mirroring the legacy
/// `tabs.first(where:)` lookups.
@MainActor
public protocol SidebarGitHosting: AnyObject {
    // MARK: Workspace/panel reads

    /// All workspace ids in sidebar order.
    func orderedWorkspaceIds() -> [UUID]
    /// Whether the workspace still exists.
    func workspaceExists(_ workspaceId: UUID) -> Bool
    /// Whether the workspace is a remote workspace; `nil` when it is gone.
    func isRemoteWorkspace(_ workspaceId: UUID) -> Bool?
    /// All panel ids in the workspace (empty when the workspace is gone).
    func panelIds(in workspaceId: UUID) -> [UUID]
    /// Whether the panel still exists in the workspace.
    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool
    /// Whether the panel is a terminal panel.
    func hasTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool
    /// Whether the panel is an active remote terminal panel.
    func isRemoteTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool
    /// The panel's git-probe directory (the sidebar directory fallback
    /// chain: live cwd, requested working directory, focused workspace
    /// directory), normalized; `nil` when unknown.
    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String?
    /// Whether the panel directory currently comes from a trusted remote report.
    func hasTrustedRemotePanelDirectory(workspaceId: UUID, panelId: UUID) -> Bool
    /// The panel's currently displayed git branch state, if any.
    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch?
    /// Returns the panel's currently displayed repository-link primitives.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace containing the panel.
    ///   - panelId: The panel whose repository link is requested.
    /// - Returns: The displayed remote name, label, and destination, or `nil`.
    func panelRepositoryLink(
        workspaceId: UUID,
        panelId: UUID
    ) -> (remoteName: String, displayName: String, url: URL)?
    /// Panel ids currently showing a git branch in the workspace.
    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID>
    /// The panel's currently displayed pull-request badge, if any.
    func panelPullRequestBadge(workspaceId: UUID, panelId: UUID) -> SidebarPullRequestBadge?
    /// Panel ids currently showing a pull-request badge in the workspace.
    func panelPullRequestPanelIds(in workspaceId: UUID) -> Set<UUID>
    /// The workspace's focused panel id, if any.
    func focusedPanelId(in workspaceId: UUID) -> UUID?
    /// Whether the workspace shows a workspace-level branch, pull-request, or
    /// repository-link signal.
    func hasWorkspaceLevelGitSignal(_ workspaceId: UUID) -> Bool
    /// Whether the panel is the focused panel of the selected workspace
    /// (drives the faster selected-panel PR poll cadence).
    func isSelectedFocusedPanel(workspaceId: UUID, panelId: UUID) -> Bool

    // MARK: Projection writes

    /// Records the panel's directory; returns `false` when nothing changed
    /// or the workspace/panel is gone. `displayLabel` optionally carries a
    /// human-friendly sidebar label reported alongside the real path.
    @discardableResult
    func updatePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool
    /// Records a trusted remote panel directory; returns `false` when nothing
    /// changed or the workspace/panel is gone.
    @discardableResult
    func updateRemotePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool
    /// Shows `branch` (with its dirty flag) on the panel.
    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool)
    /// Clears the panel's branch (and any dependent badge state).
    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID)
    /// Clears the panel's branch and dependent badge state while retaining a
    /// repository link that remains valid for a detached-head snapshot.
    func clearPanelGitBranchPreservingRepositoryLink(workspaceId: UUID, panelId: UUID)
    /// Shows a browser-safe repository link on the panel.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace containing the panel.
    ///   - panelId: The panel receiving the repository link.
    ///   - remoteName: The Git remote name that supplied the link.
    ///   - displayName: The compact repository path shown in the sidebar.
    ///   - url: The sanitized HTTP(S) browser destination.
    func updatePanelRepositoryLink(
        workspaceId: UUID,
        panelId: UUID,
        remoteName: String,
        displayName: String,
        url: URL
    )
    /// Clears the panel's repository link.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace containing the panel.
    ///   - panelId: The panel whose repository link should be cleared.
    func clearPanelRepositoryLink(workspaceId: UUID, panelId: UUID)
    /// Shows `badge` on the panel.
    func updatePanelPullRequest(workspaceId: UUID, panelId: UUID, badge: SidebarPullRequestBadge)
    /// Clears the panel's pull-request badge.
    func clearPanelPullRequest(workspaceId: UUID, panelId: UUID)
    /// Asks the host to re-probe the panel's local git metadata because the
    /// pull-request branch disagrees with the current sidebar branch projection.
    func schedulePanelGitMetadataProbe(workspaceId: UUID, panelId: UUID, reason: String)
    /// Clears every workspace's sidebar git metadata (branches, links, and badges).
    func clearAllSidebarGitMetadata()
    /// Clears every workspace's sidebar pull-request badges.
    func clearAllSidebarPullRequestMetadata()

    // MARK: Environment

    /// The active/passive/disabled work level for sidebar git metadata.
    var gitMetadataActivity: SidebarGitMetadataActivity { get }
    /// The active/passive/disabled work level for sidebar pull-request metadata.
    var pullRequestActivity: SidebarGitMetadataActivity { get }
    /// Whether the paired mobile host served a request within `interval`
    /// seconds (background git/PR work defers while true).
    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool
    /// How long until the mobile host has been quiet for `interval` seconds.
    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval
}

extension SidebarGitHosting {
    func shouldSkipLocalGitMetadata(workspaceId: UUID, panelId: UUID) -> Bool {
        isRemoteWorkspace(workspaceId) == true &&
            (isRemoteTerminalPanel(workspaceId: workspaceId, panelId: panelId) ||
                hasTrustedRemotePanelDirectory(workspaceId: workspaceId, panelId: panelId))
    }
}
