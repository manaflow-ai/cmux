import Foundation
import CmuxGit
import CmuxSidebarGit
import CmuxSidebar

// MARK: - SidebarGitHosting conformance
//
// TabManager is the window-side host of the extracted CmuxSidebarGit
// services: snapshot reads of workspace/panel state, synchronous projection
// writes of branch and PR badge state onto Workspace, and the environment
// toggles (settings + mobile-host activity) the schedulers honor. Every
// method forwards to the same Workspace/defaults accessors the legacy
// in-class subsystem used, so state transitions stay byte-identical.

extension TabManager: SidebarGitHosting {
    // MARK: Workspace/panel reads

    func orderedWorkspaceIds() -> [UUID] {
        tabs.map(\.id)
    }

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        tabs.contains(where: { $0.id == workspaceId })
    }

    func isRemoteWorkspace(_ workspaceId: UUID) -> Bool? {
        tabs.first(where: { $0.id == workspaceId })?.isRemoteWorkspace
    }

    func panelIds(in workspaceId: UUID) -> [UUID] {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Array(workspace.panels.keys)
    }

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.panels[panelId] != nil
    }

    func hasTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.terminalPanel(for: panelId) != nil
    }

    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String? {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return gitProbeDirectory(for: workspace, panelId: panelId)
    }

    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch? {
        guard let state = tabs.first(where: { $0.id == workspaceId })?.panelGitBranches[panelId] else {
            return nil
        }
        return SidebarPanelGitBranch(branch: state.branch, isDirty: state.isDirty)
    }

    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID> {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Set(workspace.panelGitBranches.keys)
    }

    func panelPullRequestBadge(workspaceId: UUID, panelId: UUID) -> SidebarPullRequestBadge? {
        guard let state = tabs.first(where: { $0.id == workspaceId })?.panelPullRequests[panelId] else {
            return nil
        }
        return state.sidebarPullRequestBadge
    }

    func panelPullRequestPanelIds(in workspaceId: UUID) -> Set<UUID> {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Set(workspace.panelPullRequests.keys)
    }

    func focusedPanelId(in workspaceId: UUID) -> UUID? {
        tabs.first(where: { $0.id == workspaceId })?.focusedPanelId
    }

    func hasWorkspaceLevelGitSignal(_ workspaceId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.gitBranch != nil || workspace.pullRequest != nil
    }

    func isSelectedFocusedPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        selectedWorkspace?.id == workspaceId && selectedWorkspace?.focusedPanelId == panelId
    }

    // MARK: Projection writes

    @discardableResult
    func updatePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.updatePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel)
    }

    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool) {
        tabs.first(where: { $0.id == workspaceId })?
            .updatePanelGitBranch(panelId: panelId, branch: branch, isDirty: isDirty)
    }

    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.clearPanelGitBranch(panelId: panelId)
    }

    func updatePanelPullRequest(workspaceId: UUID, panelId: UUID, badge: SidebarPullRequestBadge) {
        tabs.first(where: { $0.id == workspaceId })?.updatePanelPullRequest(
            panelId: panelId,
            number: badge.number,
            label: badge.label,
            url: badge.url,
            // Raw values are shared between the app and package status enums.
            status: SidebarPullRequestStatus(rawValue: badge.status.rawValue) ?? .open,
            branch: badge.branch,
            isStale: badge.isStale,
            ciStatus: SidebarPullRequestCIStatus(badge.ciStatus)
        )
    }

    func clearPanelPullRequest(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.clearPanelPullRequest(panelId: panelId)
    }

    func clearAllSidebarGitMetadata() {
        for workspace in tabs {
            workspace.clearSidebarGitMetadata()
        }
    }

    func clearAllSidebarPullRequestMetadata() {
        for workspace in tabs {
            workspace.clearSidebarPullRequestMetadata()
        }
    }

    // MARK: Environment

    var isGitMetadataWatchEnabled: Bool {
        SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    }

    var isPullRequestPollingEnabled: Bool {
        SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard)
    }

    var isPullRequestCIStatusEnabled: Bool {
        isPullRequestPollingEnabled
            && SidebarWorkspaceDetailDefaults.showPullRequestCIStatusValue(defaults: .standard)
    }

    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool {
        MobileHostRequestActivity.hasRecentActivity(within: interval)
    }

    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval {
        MobileHostRequestActivity.quietDelay(for: interval)
    }
}

extension SidebarPullRequestState {
    /// The package wire value for this badge (status bridges by shared raw
    /// value: open/merged/closed).
    var sidebarPullRequestBadge: SidebarPullRequestBadge {
        SidebarPullRequestBadge(
            number: number,
            label: label,
            url: url,
            status: PullRequestStatus(rawValue: status.rawValue) ?? .open,
            branch: branch,
            isStale: isStale,
            ciStatus: PullRequestCIStatus(ciStatus)
        )
    }
}

private extension SidebarPullRequestCIStatus {
    init(_ status: PullRequestCIStatus) {
        switch status {
        case .neutral:
            self = .neutral
        case .success:
            self = .success
        case .failure:
            self = .failure
        }
    }
}

private extension PullRequestCIStatus {
    init(_ status: SidebarPullRequestCIStatus) {
        switch status {
        case .neutral:
            self = .neutral
        case .success:
            self = .success
        case .failure:
            self = .failure
        }
    }
}
