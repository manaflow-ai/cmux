public import Foundation

/// The window-side seam the sidebar git services drive: snapshot reads of
/// workspace/panel state, synchronous projection writes of branch and
/// pull-request badges, and the environment toggles the schedulers honor.
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
    /// The panel's git-probe directory (the sidebar directory fallback
    /// chain: live cwd, requested working directory, focused workspace
    /// directory), normalized; `nil` when unknown.
    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String?
    /// The panel's currently displayed git branch state, if any.
    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch?
    /// Panel ids currently showing a git branch in the workspace.
    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID>
    /// The panel's currently displayed pull-request badge, if any.
    func panelPullRequestBadge(workspaceId: UUID, panelId: UUID) -> SidebarPullRequestBadge?
    /// Panel ids currently showing a pull-request badge in the workspace.
    func panelPullRequestPanelIds(in workspaceId: UUID) -> Set<UUID>
    /// The workspace's focused panel id, if any.
    func focusedPanelId(in workspaceId: UUID) -> UUID?
    /// Whether the workspace shows a workspace-level git branch or
    /// pull-request signal (the legacy `gitBranch != nil || pullRequest != nil`).
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
    /// Shows `branch` (with its dirty flag) on the panel.
    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool)
    /// Clears the panel's branch (and any dependent badge state).
    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID)
    /// Shows `badge` on the panel.
    func updatePanelPullRequest(workspaceId: UUID, panelId: UUID, badge: SidebarPullRequestBadge)
    /// Clears the panel's pull-request badge.
    func clearPanelPullRequest(workspaceId: UUID, panelId: UUID)
    /// Clears every workspace's sidebar git metadata (branches and badges).
    func clearAllSidebarGitMetadata()
    /// Clears every workspace's sidebar pull-request badges.
    func clearAllSidebarPullRequestMetadata()

    // MARK: Environment

    /// Whether the sidebar git status watch setting is enabled.
    var isGitMetadataWatchEnabled: Bool { get }
    /// Whether sidebar pull-request polling is enabled.
    var isPullRequestPollingEnabled: Bool { get }
    /// Whether the paired mobile host served a request within `interval`
    /// seconds (background git/PR work defers while true).
    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool
    /// How long until the mobile host has been quiet for `interval` seconds.
    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval
}
