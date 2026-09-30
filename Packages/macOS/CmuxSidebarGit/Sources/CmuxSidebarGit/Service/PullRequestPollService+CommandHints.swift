public import Foundation
import CmuxGit

// MARK: - Settings toggles, command-hint reconciliation, and test seams.

extension PullRequestPollService {
    // MARK: Settings

    public func sidebarPullRequestPollingSettingsDidChange() {
        let activity = sidebarPullRequestActivity
        guard activity != lastSidebarPullRequestActivity else {
            return
        }
        lastSidebarPullRequestActivity = activity

        guard activity.performsActivePolling else {
            stopWorkspacePullRequestPolling(activity: activity)
            return
        }

        refreshTrackedWorkspacePullRequestsIfNeeded(reason: "pullRequestVisibilityEnabled")
    }

    // MARK: Command hints

    public func handleWorkspacePullRequestCommandHint(
        workspaceId: UUID,
        panelId: UUID,
        action: String,
        target: String?
    ) {
        guard let host, host.workspaceExists(workspaceId) else { return }
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let activity = sidebarPullRequestActivity
        guard activity.acceptsPassiveReports else {
            stopWorkspacePullRequestPolling(for: key, activity: activity)
            return
        }
        reconcileLocalPullRequestActionIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            action: action,
            target: target
        )
        guard activity.performsActivePolling else {
            stopWorkspacePullRequestPolling(for: key, activity: activity)
            return
        }
        scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "commandHint:\(action)"
        )
    }

    func reconcileLocalPullRequestActionIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        action: String,
        target: String?
    ) {
        guard let host,
              let currentPullRequest = host.panelPullRequestBadge(workspaceId: workspaceId, panelId: panelId),
              pullRequestCommandTargetMatchesCurrentPullRequest(
                target,
                currentPullRequest: currentPullRequest
              ) else {
            return
        }

        let nextStatus: PullRequestStatus
        switch action {
        case "merge":
            guard currentPullRequest.status == .open else { return }
            nextStatus = .merged
        case "close":
            guard currentPullRequest.status == .open else { return }
            nextStatus = .closed
        case "reopen":
            guard currentPullRequest.status != .open else { return }
            nextStatus = .open
        default:
            return
        }

        host.updatePanelPullRequest(
            workspaceId: workspaceId,
            panelId: panelId,
            badge: SidebarPullRequestBadge(
                number: currentPullRequest.number,
                label: currentPullRequest.label,
                url: currentPullRequest.url,
                status: nextStatus,
                branch: currentPullRequest.branch,
                isStale: false
            )
        )
    }

    func pullRequestCommandTargetMatchesCurrentPullRequest(
        _ rawTarget: String?,
        currentPullRequest: SidebarPullRequestBadge
    ) -> Bool {
        let trimmedTarget = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTarget.isEmpty else { return true }

        let numberToken = trimmedTarget.hasPrefix("#") ? String(trimmedTarget.dropFirst()) : trimmedTarget
        if let number = Int(numberToken), number == currentPullRequest.number {
            return true
        }

        if let targetURL = URL(string: trimmedTarget) {
            if targetURL == currentPullRequest.url {
                return true
            }
            if let lastComponent = targetURL.pathComponents.last,
               let number = Int(lastComponent),
               number == currentPullRequest.number {
                return true
            }
        }

        if GitMetadataService.normalizedBranchName(trimmedTarget) == GitMetadataService.normalizedBranchName(currentPullRequest.branch) {
            return true
        }

        return false
    }

    // MARK: Test seams

    public func workspacePullRequestTrackedPanelIds(workspaceId: UUID) -> Set<UUID> {
        let probeKeys = Set(workspacePullRequestProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspacePullRequestNextPollAtByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspacePullRequestLastTerminalStateRefreshAtByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspacePullRequestTransientFailureCountByKey.keys.filter { $0.workspaceId == workspaceId })
        return Set(probeKeys.map(\.panelId))
    }
}
