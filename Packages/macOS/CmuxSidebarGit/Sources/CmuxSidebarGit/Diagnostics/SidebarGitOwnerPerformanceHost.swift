import Foundation

/// Minimal in-memory host for the Release-safe owner exercise.
@MainActor
final class SidebarGitOwnerPerformanceHost: SidebarGitHosting {
    let workspaceId = UUID()
    let panelId = UUID()
    let directory = "/isolated/owner-proof"
    var branch: String
    private(set) var badge: SidebarPullRequestBadge?
    private(set) var badgeApplyCount = 0
    private var badgeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(branch: String) {
        self.branch = branch
    }

    func waitForBadgeApplyCount(_ minimumCount: Int) async {
        guard badgeApplyCount < minimumCount else { return }
        await withCheckedContinuation { badgeWaiters.append((minimumCount, $0)) }
    }

    func orderedWorkspaceIds() -> [UUID] { [workspaceId] }
    func workspaceExists(_ workspaceId: UUID) -> Bool { workspaceId == self.workspaceId }
    func isRemoteWorkspace(_ workspaceId: UUID) -> Bool? {
        workspaceExists(workspaceId) ? false : nil
    }
    func panelIds(in workspaceId: UUID) -> [UUID] {
        workspaceExists(workspaceId) ? [panelId] : []
    }
    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        workspaceId == self.workspaceId && panelId == self.panelId
    }
    func hasTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        panelExists(workspaceId: workspaceId, panelId: panelId)
    }
    func isRemoteTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool { false }
    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String? {
        panelExists(workspaceId: workspaceId, panelId: panelId) ? directory : nil
    }
    func hasTrustedRemotePanelDirectory(workspaceId: UUID, panelId: UUID) -> Bool { false }
    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch? {
        guard panelExists(workspaceId: workspaceId, panelId: panelId) else { return nil }
        return SidebarPanelGitBranch(branch: branch, isDirty: false)
    }
    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID> {
        workspaceExists(workspaceId) ? [panelId] : []
    }
    func panelPullRequestBadge(workspaceId: UUID, panelId: UUID) -> SidebarPullRequestBadge? {
        panelExists(workspaceId: workspaceId, panelId: panelId) ? badge : nil
    }
    func panelPullRequestPanelIds(in workspaceId: UUID) -> Set<UUID> {
        workspaceExists(workspaceId) && badge != nil ? [panelId] : []
    }
    func focusedPanelId(in workspaceId: UUID) -> UUID? {
        workspaceExists(workspaceId) ? panelId : nil
    }
    func hasWorkspaceLevelGitSignal(_ workspaceId: UUID) -> Bool {
        workspaceExists(workspaceId)
    }
    func isSelectedFocusedPanel(workspaceId: UUID, panelId: UUID) -> Bool { false }

    func updatePanelDirectory(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        displayLabel: String?
    ) -> Bool { false }
    func updateRemotePanelDirectory(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        displayLabel: String?
    ) -> Bool { false }
    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool) {}
    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID) {}
    func updatePanelPullRequest(
        workspaceId: UUID,
        panelId: UUID,
        badge: SidebarPullRequestBadge
    ) {
        guard panelExists(workspaceId: workspaceId, panelId: panelId) else { return }
        self.badge = badge
        badgeApplyCount += 1
        let ready = badgeWaiters.filter { $0.0 <= badgeApplyCount }
        badgeWaiters.removeAll { $0.0 <= badgeApplyCount }
        for waiter in ready { waiter.1.resume() }
    }
    func clearPanelPullRequest(workspaceId: UUID, panelId: UUID) { badge = nil }
    func schedulePanelGitMetadataProbe(workspaceId: UUID, panelId: UUID, reason: String) {}
    func clearAllSidebarGitMetadata() { badge = nil }
    func clearAllSidebarPullRequestMetadata() { badge = nil }

    var isGitMetadataWatchEnabled: Bool { true }
    var isPullRequestPollingEnabled: Bool { true }
    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool { false }
    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval { 0 }
}
