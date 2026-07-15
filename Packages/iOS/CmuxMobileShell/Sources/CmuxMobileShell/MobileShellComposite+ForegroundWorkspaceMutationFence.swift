internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

nonisolated private let foregroundWorkspaceMutationLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

struct ForegroundWorkspaceMutationRefreshResult: Sendable {
    let epoch: UInt64
    let succeeded: Bool
}

extension MobileShellComposite {
    /// Claims selection ownership across workspace and terminal creates. Their
    /// RPCs have separate single-flight owners and can overlap, so only the most
    /// recently started create may select its result after an await.
    func claimForegroundCreateSelection() -> UInt64 {
        foregroundCreateSelectionRevision &+= 1
        return foregroundCreateSelectionRevision
    }

    func ownsForegroundCreateSelection(_ revision: UInt64) -> Bool {
        revision == foregroundCreateSelectionRevision
    }

    /// Installs a create response only while it still owns the hierarchy epoch
    /// and no newer workspace list has been installed. A mutation or ordinary
    /// authoritative list invalidates that scoped snapshot; in either case a
    /// fresh post-mutation list becomes the sole hierarchy writer.
    func applyOrReconcileRemoteCreateResponse(
        _ response: MobileSyncWorkspaceListResponse,
        startedAt mutationEpoch: UInt64,
        listRevision: UInt64,
        focusRevision: UInt64,
        client: MobileCoreRPCClient,
        generation: UUID
    ) async -> RemoteCreateResponseOutcome {
        guard isCurrentRemoteOperation(client: client, generation: generation),
              !Task.isCancelled else { return .invalidated }
        if mutationEpoch == foregroundWorkspaceListMutationEpoch,
           listRevision == foregroundWorkspaceListAppliedRevision {
            advanceForegroundWorkspaceListMutationEpoch()
            applyRemoteWorkspaceList(
                response,
                mergeExistingWorkspaces: true,
                listStartedAtFocusRevision: focusRevision
            )
            markForegroundWorkspaceListApplied(through: mutationEpoch)
            return .appliedScopedResponse
        }
        let reconciled = await refreshForegroundWorkspaceListAfterMutation()
        guard isCurrentRemoteOperation(client: client, generation: generation),
              !Task.isCancelled else { return .invalidated }
        return reconciled ? .reconciledAuthoritativeList : .reconciliationRequired
    }

    /// Re-fetches and installs the foreground Mac's authoritative workspace list.
    func reloadWorkspaceListFromMac(
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        let mutationEpoch = foregroundWorkspaceListMutationEpoch
        let focusRevision = workspaceFocusRevisionSnapshot()
        do {
            let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.rpcRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(data)
            guard remoteClient === client,
                  connectionState == .connected,
                  mutationEpoch == foregroundWorkspaceListMutationEpoch else { return false }
            applyRemoteWorkspaceList(
                response,
                preferActiveTicketTarget: false,
                listStartedAtFocusRevision: focusRevision
            )
            markForegroundWorkspaceListApplied(through: mutationEpoch)
            syncSelectedTerminalForWorkspace()
            return true
        } catch {
            foregroundWorkspaceMutationLog.error(
                "workspace list event refresh failed: \(String(describing: error), privacy: .private)"
            )
            if remoteClient === client {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
    }

    /// Refresh only the foreground Mac and report whether an authoritative list
    /// was installed. Mutation reconciliation uses this result to fail closed.
    func refreshForegroundWorkspaceList() async -> Bool {
        guard connectionState == .connected, remoteClient != nil else { return false }
        if let inFlight = pullToRefreshTask {
            return await inFlight.value
        }
        let taskID = UUID()
        let task: Task<Bool, Never> = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.pullToRefreshTaskID == taskID {
                    self.pullToRefreshTask = nil
                    self.pullToRefreshTaskID = nil
                }
            }
            return await self.reloadWorkspaceListFromMac()
        }
        pullToRefreshTask = task
        pullToRefreshTaskID = taskID
        return await task.value
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
    func markForegroundWorkspaceListApplied(through epoch: UInt64) {
        foregroundWorkspaceListAppliedMutationEpoch = max(
            foregroundWorkspaceListAppliedMutationEpoch,
            epoch
        )
    }
}
