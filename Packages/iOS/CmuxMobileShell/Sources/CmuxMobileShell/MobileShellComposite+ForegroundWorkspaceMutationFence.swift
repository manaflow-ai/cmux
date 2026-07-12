internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let foregroundWorkspaceMutationLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

struct ForegroundWorkspaceMutationRefreshResult: Sendable {
    let epoch: UInt64
    let succeeded: Bool
}

extension MobileShellComposite {
    /// Re-fetches and installs the foreground Mac's authoritative workspace list.
    func reloadWorkspaceListFromMac() async -> Bool {
        guard let client = remoteClient else { return false }
        let mutationEpoch = foregroundWorkspaceListMutationEpoch
        do {
            let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: runtime?.rpcRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(data)
            guard remoteClient === client,
                  connectionState == .connected,
                  mutationEpoch == foregroundWorkspaceListMutationEpoch else { return false }
            applyRemoteWorkspaceList(response, preferActiveTicketTarget: false)
            markForegroundWorkspaceListApplied()
            syncSelectedTerminalForWorkspace()
            return true
        } catch {
            foregroundWorkspaceMutationLog.error(
                "workspace list event refresh failed: \(String(describing: error), privacy: .private)"
            )
            return false
        }
    }

    /// Starts a foreground read after a mutation acknowledgement. An older pull
    /// may contain the pre-mutation hierarchy, so it must settle before this read.
    func refreshForegroundWorkspaceListAfterMutation() async -> Bool {
        let epoch = advanceForegroundWorkspaceListMutationEpoch()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return ForegroundWorkspaceMutationRefreshResult(epoch: epoch, succeeded: false)
            }
            if let inFlight = self.pullToRefreshTask {
                _ = await inFlight.value
            }
            guard self.connectionState == .connected, self.remoteClient != nil else {
                return ForegroundWorkspaceMutationRefreshResult(epoch: epoch, succeeded: false)
            }
            let succeeded = await self.reloadWorkspaceListFromMac()
            return ForegroundWorkspaceMutationRefreshResult(epoch: epoch, succeeded: succeeded)
        }
        foregroundWorkspaceMutationRefreshTask = task
        foregroundWorkspaceMutationRefreshTaskID = taskID
        let result = await task.value
        if foregroundWorkspaceMutationRefreshTaskID == taskID {
            foregroundWorkspaceMutationRefreshTask = nil
            foregroundWorkspaceMutationRefreshTaskID = nil
        }
        if result.succeeded || foregroundWorkspaceListAppliedMutationEpoch >= epoch {
            return true
        }
        guard foregroundWorkspaceListMutationEpoch > epoch,
              let latestTask = foregroundWorkspaceMutationRefreshTask else { return false }
        let latestResult = await latestTask.value
        return foregroundWorkspaceListAppliedMutationEpoch >= epoch
            || (latestResult.epoch >= epoch && latestResult.succeeded)
    }

    /// Invalidates foreground list reads that started before a mutation response.
    @discardableResult
    func advanceForegroundWorkspaceListMutationEpoch() -> UInt64 {
        foregroundWorkspaceListMutationEpoch &+= 1
        return foregroundWorkspaceListMutationEpoch
    }

    /// Records the newest mutation epoch represented by an installed list.
    func markForegroundWorkspaceListApplied() {
        foregroundWorkspaceListAppliedMutationEpoch = max(
            foregroundWorkspaceListAppliedMutationEpoch,
            foregroundWorkspaceListMutationEpoch
        )
    }
}
