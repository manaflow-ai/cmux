import Foundation

/// Minimal in-memory host for the Release-safe owner exercise.
@MainActor
final class SidebarGitOwnerPerformanceHost: SidebarGitHosting {
    private struct BadgeWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    let workspaceId = UUID()
    let panelId = UUID()
    let directory = "/isolated/owner-proof"
    var branch: String
    private(set) var badge: SidebarPullRequestBadge?
    private(set) var badgeApplyCount = 0
    private let suppressesBadgeApplySignal: Bool
    private var badgeWaitersByID: [UUID: BadgeWaiter] = [:]

    init(branch: String, suppressesBadgeApplySignal: Bool = false) {
        self.branch = branch
        self.suppressesBadgeApplySignal = suppressesBadgeApplySignal
    }

    func waitForBadgeApplyCount(_ minimumCount: Int) async throws {
        guard badgeApplyCount < minimumCount else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                badgeWaitersByID[waiterID] = BadgeWaiter(
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelBadgeWaiter(waiterID)
            }
        }
    }

    func cancelAllPendingBadgeWaits() {
        let waiters = Array(badgeWaitersByID.values)
        badgeWaitersByID.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    var pendingBadgeWaiterCount: Int { badgeWaitersByID.count }

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
        guard !suppressesBadgeApplySignal else { return }
        badgeApplyCount += 1
        let readyIDs = badgeWaitersByID.compactMap { id, waiter in
            waiter.minimumCount <= badgeApplyCount ? id : nil
        }
        for waiterID in readyIDs {
            badgeWaitersByID.removeValue(forKey: waiterID)?
                .continuation.resume(returning: ())
        }
    }
    func clearPanelPullRequest(workspaceId: UUID, panelId: UUID) { badge = nil }
    func schedulePanelGitMetadataProbe(workspaceId: UUID, panelId: UUID, reason: String) {}
    func clearAllSidebarGitMetadata() { badge = nil }
    func clearAllSidebarPullRequestMetadata() { badge = nil }

    var isGitMetadataWatchEnabled: Bool { true }
    var isPullRequestPollingEnabled: Bool { true }
    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool { false }
    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval { 0 }

    private func cancelBadgeWaiter(_ waiterID: UUID) {
        badgeWaitersByID.removeValue(forKey: waiterID)?
            .continuation.resume(throwing: CancellationError())
    }
}
