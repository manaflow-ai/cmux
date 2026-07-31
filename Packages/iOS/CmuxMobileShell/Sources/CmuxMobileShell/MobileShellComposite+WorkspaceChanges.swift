public import CmuxMobileRPC
internal import CmuxMobileDiagnostics
internal import CmuxMobileShellModel
internal import Foundation

/// Shell-owned failure categories for single-workspace changes reads, so UI
/// callers can distinguish "not a repository" from transport/decoding failures
/// without importing the RPC module's error type.
public enum WorkspaceChangesFetchError: Error, Sendable, Equatable {
    /// The workspace's effective directory is not inside a Git repository.
    case notARepository
    /// Any other connection, authorization, RPC, or decoding failure.
    case transport
}

extension MobileShellComposite {
    /// Returns the unseen one-time hint for a changed workspace, when eligible.
    /// - Parameter workspaceID: Mac-local workspace identifier.
    /// - Returns: A value snapshot for UI presentation, or `nil` when hidden.
    public func workspaceChangesHint(workspaceID: String) -> MobileWorkspaceChangesHint? {
        let chip = workspaceChangeChipsByWorkspaceID[workspaceID]
        let isDismissed = workspaceChangesHintDismissalStore.isDismissed(workspaceID: workspaceID)
        let hint = MobileWorkspaceChangesHint(
            workspaceID: workspaceID,
            workspaceChangesCapable: workspaceChangesCapable,
            chip: chip,
            isDismissed: isDismissed
        )
        MobileDebugLog.anchormux(
            "changes.hint eval ws=\(workspaceID.prefix(8)) capable=\(workspaceChangesCapable) files=\(chip?.filesChanged ?? -1) dismissed=\(isDismissed) shown=\(hint != nil)"
        )
        return hint
    }

    /// Permanently marks the one-time changes hint as seen for a workspace.
    /// - Parameter workspaceID: Mac-local workspace identifier.
    public func dismissWorkspaceChangesHint(workspaceID: String) {
        workspaceChangesHintDismissalStore.dismiss(workspaceID: workspaceID)
    }

    /// Fetches summary chips in batches of at most 64 workspaces.
    ///
    /// A successful workspace fetch is reused for 15 seconds unless `force` is
    /// true. Failures leave the last published chip snapshot intact.
    /// - Parameters:
    ///   - workspaceIDs: Mac-local workspace identifiers.
    ///   - force: Whether to bypass the client-side reuse window.
    public func fetchWorkspaceChangesSummaries(
        workspaceIDs: [String],
        force: Bool = false
    ) async {
        guard workspaceChangesCapable,
              connectionState == .connected,
              let client = remoteClient else {
            MobileDebugLog.anchormux(
                "changes.summary skip capable=\(workspaceChangesCapable) state=\(connectionState) client=\(remoteClient != nil)"
            )
            return
        }
        let foregroundWorkspaceSet = pruneWorkspaceChangesSummaryStateToForeground()
        let retainedWorkspaceIDs = foregroundWorkspaceSet.workspaceIDs(
            retaining: workspaceIDs
        )
        let now = runtime?.now() ?? Date()
        let plan = workspaceChangesSummaryFetchPolicy.plan(
            workspaceIDs: retainedWorkspaceIDs,
            fetchedAtByWorkspaceID: workspaceChangesSummaryFetchedAtByWorkspaceID,
            now: now,
            force: force
        )
        armWorkspaceChangesSummaryTrailingRefreshIfActive(
            freshUntilByWorkspaceID: plan.freshUntilByWorkspaceID,
            now: now
        )

        for batch in plan.batches {
            guard !Task.isCancelled,
                  remoteClient === client,
                  connectionState == .connected else { return }
            do {
                guard let summaryRequest = MobileWorkspaceChangesSummaryRequest(
                    workspaceIDs: batch,
                    force: force
                ) else { continue }
                var params: [String: Any] = [
                    "workspace_ids": summaryRequest.workspaceIDs,
                ]
                if summaryRequest.force {
                    params["force"] = true
                }
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.workspace.changes.summary",
                    params: params
                )
                let data = try await client.sendRequest(request)
                let response = try MobileWorkspaceChangesSummariesResponse.decode(data)
                guard remoteClient === client, connectionState == .connected else { return }
                let batchFetchedAt = runtime?.now() ?? Date()
                let currentWorkspaceSet = pruneWorkspaceChangesSummaryStateToForeground()
                let retainedBatch = currentWorkspaceSet.workspaceIDs(retaining: batch)

                var chips = workspaceChangeChipsByWorkspaceID
                for summary in response.summaries
                    where currentWorkspaceSet.contains(summary.workspaceID) {
                    if summary.isRepository, summary.filesChanged > 0 {
                        chips[summary.workspaceID] = MobileWorkspaceChangesChip(
                            filesChanged: summary.filesChanged,
                            additions: summary.additions,
                            deletions: summary.deletions
                        )
                    } else {
                        chips.removeValue(forKey: summary.workspaceID)
                    }
                }
                setWorkspaceChangeChipsByWorkspaceID(chips)
                MobileDebugLog.anchormux(
                    "changes.summary ok requested=\(batch.count) summaries=\(response.summaries.count) chips=\(chips.count) sample=\(chips.keys.sorted().first.map { String($0.prefix(8)) } ?? "-") reqSample=\(batch.first.map { String($0.prefix(8)) } ?? "-")"
                )
                for workspaceID in retainedBatch {
                    workspaceChangesSummaryFetchedAtByWorkspaceID[workspaceID] = batchFetchedAt
                    workspaceChangesSummaryTrailingExpiryByWorkspaceID
                        .removeValue(forKey: workspaceID)
                }
                armWorkspaceChangesSummaryTrailingRefreshIfActive(
                    freshUntilByWorkspaceID: workspaceChangesSummaryFetchPolicy
                        .freshUntilAfterSuccessfulFetch(
                            workspaceIDs: retainedBatch,
                            fetchedAt: batchFetchedAt
                        ),
                    now: batchFetchedAt
                )
            } catch {
                MobileDebugLog.anchormux("changes.summary error \(error)")
                guard !Task.isCancelled, remoteClient === client else { return }
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
        }
        rescheduleWorkspaceChangesSummaryTrailingTask()
    }

    /// Fetches the changed-file list for one workspace.
    /// - Parameter workspaceID: Mac-local workspace identifier.
    /// - Returns: The decoded changed-file response.
    /// - Throws: A connection, authorization, RPC, or decoding error.
    public func fetchChangedFiles(
        workspaceID: String
    ) async throws -> MobileWorkspaceChangedFilesResponse {
        let client = try workspaceChangesClient()
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.workspace.changes.files",
            params: ["workspace_id": workspaceID]
        )
        let data: Data
        do {
            data = try await client.sendRequest(request)
        } catch let error as MobileShellConnectionError {
            throw Self.workspaceChangesFetchError(error)
        }
        guard remoteClient === client, connectionState == .connected else {
            throw CancellationError()
        }
        return try MobileWorkspaceChangedFilesResponse.decode(data)
    }

    /// Decodes a potentially multi-megabyte file-diff payload off the main
    /// actor (SE-0338: nonisolated async runs on the generic executor), so a
    /// Show more response never runs a large JSON pass on the UI thread.
    nonisolated static func decodeFileDiffResponse(
        _ data: Data
    ) async throws -> MobileWorkspaceFileDiffResponse {
        try MobileWorkspaceFileDiffResponse.decode(data)
    }

    /// Maps the RPC connection error onto the shell-owned fetch failure so UI
    /// callers can render a dedicated non-repository state.
    nonisolated static func workspaceChangesFetchError(
        _ error: MobileShellConnectionError
    ) -> WorkspaceChangesFetchError {
        if case let .rpcError(code, _) = error, code == "not_a_repo" {
            return .notARepository
        }
        return .transport
    }

    /// Fetches a progressively bounded unified diff for one changed path.
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - path: Repository-relative changed path.
    ///   - maxLines: Optional progressive line budget.
    /// - Returns: The decoded file-diff response.
    /// - Throws: A connection, authorization, RPC, or decoding error.
    public func fetchFileDiff(
        workspaceID: String,
        path: String,
        maxLines: Int? = nil
    ) async throws -> MobileWorkspaceFileDiffResponse {
        let client = try workspaceChangesClient()
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "path": path,
        ]
        if let maxLines {
            params["max_lines"] = maxLines
        }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.workspace.changes.file_diff",
            params: params
        )
        let data = try await client.sendRequest(request)
        guard remoteClient === client, connectionState == .connected else {
            throw CancellationError()
        }
        return try await Self.decodeFileDiffResponse(data)
    }

    func scheduleWorkspaceChangesSummaryRefresh(
        workspaceIDs explicitWorkspaceIDs: [String]? = nil,
        force: Bool = false,
        isTrailingPass: Bool = false
    ) {
        guard workspaceChangesCapable,
              connectionState == .connected,
              remoteClient != nil else { return }
        if !isTrailingPass {
            workspaceChangesSummaryLastEventAt = runtime?.now() ?? Date()
        }
        let requestedScope: WorkspaceChangesSummaryRefreshScope
        if let explicitWorkspaceIDs {
            let retainedWorkspaceIDs = WorkspaceChangesSummaryWorkspaceSet(
                workspaceIDs: foregroundWorkspaceChangesIDs
            ).workspaceIDs(retaining: explicitWorkspaceIDs)
            guard !retainedWorkspaceIDs.isEmpty else {
                MobileDebugLog.anchormux("changes.schedule skip: no foreground workspace ids")
                return
            }
            requestedScope = .workspaceDelta(retainedWorkspaceIDs)
        } else {
            guard !foregroundWorkspaceChangesIDs.isEmpty else {
                MobileDebugLog.anchormux("changes.schedule skip: no foreground workspace ids")
                return
            }
            requestedScope = .fullSnapshot
        }
        let shouldRestartDebounce = workspaceChangesSummaryRefreshSchedulePolicy.schedule(
            scope: requestedScope,
            force: force
        )
        guard shouldRestartDebounce else { return }

        workspaceChangesSummaryDebounceTask?.cancel()
        let taskID = UUID()
        workspaceChangesSummaryDebounceTaskID = taskID
        let debounceClock = workspaceChangesSchedulingClock
        workspaceChangesSummaryDebounceTask = Task { @MainActor [weak self] in
            // A bounded, cancellable delay is the intended event/list debounce.
            try? await debounceClock.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  self.workspaceChangesSummaryDebounceTaskID == taskID else { return }
            self.clearWorkspaceChangesSummaryDebounceTask(id: taskID)
            guard let request =
                self.workspaceChangesSummaryRefreshSchedulePolicy.beginFetchAfterDebounce()
            else {
                return
            }
            self.startWorkspaceChangesSummaryFetch(
                scope: request.scope,
                force: request.force
            )
        }
    }

    var foregroundWorkspaceChangesIDs: [String] {
        workspaces.compactMap { workspace in
            guard workspace.macDeviceID == nil || workspace.macDeviceID == foregroundMacDeviceID else {
                return nil
            }
            return workspace.rpcWorkspaceID.rawValue
        }
    }

    func workspaceChangesClient() throws -> MobileCoreRPCClient {
        guard workspaceChangesCapable else {
            throw MobileShellConnectionError.invalidResponse
        }
        guard connectionState == .connected, let remoteClient else {
            throw MobileShellConnectionError.connectionClosed
        }
        return remoteClient
    }

    private func startWorkspaceChangesSummaryFetch(
        scope initialScope: WorkspaceChangesSummaryRefreshScope,
        force initialForce: Bool
    ) {
        guard workspaceChangesSummaryFetchTask == nil else { return }
        let taskID = UUID()
        workspaceChangesSummaryFetchTaskID = taskID
        workspaceChangesSummaryFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var scope = initialScope
            var force = initialForce
            while true {
                let workspaceIDs = scope.workspaceIDs(
                    fullSnapshotWorkspaceIDs: self.foregroundWorkspaceChangesIDs
                )
                if !workspaceIDs.isEmpty {
                    await self.fetchWorkspaceChangesSummaries(
                        workspaceIDs: workspaceIDs,
                        force: force
                    )
                }
                guard self.workspaceChangesSummaryFetchTaskID == taskID else { return }
                guard let trailingRequest =
                    self.workspaceChangesSummaryRefreshSchedulePolicy.fetchCompleted()
                else {
                    self.clearWorkspaceChangesSummaryFetchTask(id: taskID)
                    return
                }
                scope = trailingRequest.scope
                force = trailingRequest.force
            }
        }
    }

    private func clearWorkspaceChangesSummaryDebounceTask(id: UUID) {
        guard workspaceChangesSummaryDebounceTaskID == id else { return }
        workspaceChangesSummaryDebounceTask = nil
        workspaceChangesSummaryDebounceTaskID = nil
    }

    private func clearWorkspaceChangesSummaryFetchTask(id: UUID) {
        guard workspaceChangesSummaryFetchTaskID == id else { return }
        workspaceChangesSummaryFetchTask = nil
        workspaceChangesSummaryFetchTaskID = nil
    }

    /// Arms the trailing expiry only while workspace events are recent, so a
    /// trailing pass on an idle connection cannot self-perpetuate a
    /// 15-second git polling loop on the Mac. The next real event resumes
    /// refreshing immediately.
    private func armWorkspaceChangesSummaryTrailingRefreshIfActive(
        freshUntilByWorkspaceID: [String: Date],
        now: Date
    ) {
        guard let lastEventAt = workspaceChangesSummaryLastEventAt,
              now.timeIntervalSince(lastEventAt)
                <= workspaceChangesSummaryFetchPolicy.reuseWindow else {
            return
        }
        armWorkspaceChangesSummaryTrailingRefresh(
            freshUntilByWorkspaceID: freshUntilByWorkspaceID
        )
    }

    private func armWorkspaceChangesSummaryTrailingRefresh(
        freshUntilByWorkspaceID: [String: Date]
    ) {
        let workspaceSet = pruneWorkspaceChangesSummaryStateToForeground()
        for (workspaceID, expiry) in freshUntilByWorkspaceID
            where workspaceSet.contains(workspaceID) {
            let existing = workspaceChangesSummaryTrailingExpiryByWorkspaceID[workspaceID]
            workspaceChangesSummaryTrailingExpiryByWorkspaceID[workspaceID] =
                existing.map { min($0, expiry) } ?? expiry
        }
        rescheduleWorkspaceChangesSummaryTrailingTask()
    }

    func rescheduleWorkspaceChangesSummaryTrailingTask() {
        _ = pruneWorkspaceChangesSummaryStateToForeground()
        guard let deadline =
            workspaceChangesSummaryTrailingExpiryByWorkspaceID.values.min()
        else {
            workspaceChangesSummaryTrailingTask?.cancel()
            workspaceChangesSummaryTrailingTask = nil
            workspaceChangesSummaryTrailingTaskID = nil
            workspaceChangesSummaryTrailingDeadline = nil
            return
        }
        if workspaceChangesSummaryTrailingTask != nil,
           workspaceChangesSummaryTrailingDeadline == deadline {
            return
        }

        workspaceChangesSummaryTrailingTask?.cancel()
        let taskID = UUID()
        workspaceChangesSummaryTrailingTaskID = taskID
        workspaceChangesSummaryTrailingDeadline = deadline
        workspaceChangesSummaryTrailingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let now = self.runtime?.now() ?? Date()
            let delayMilliseconds = Int64(ceil(
                self.workspaceChangesSummaryFetchPolicy.trailingRefreshDelay(
                    deadline: deadline,
                    now: now
                ) * 1_000
            ))
            // A bounded, cancellable delay intentionally fires at the earliest cache expiry.
            try? await self.workspaceChangesSchedulingClock.sleep(
                for: .milliseconds(delayMilliseconds)
            )
            guard !Task.isCancelled,
                  self.workspaceChangesSummaryTrailingTaskID == taskID else {
                return
            }
            self.fireWorkspaceChangesSummaryTrailingRefresh(deadline: deadline)
        }
    }

    private func fireWorkspaceChangesSummaryTrailingRefresh(deadline: Date) {
        workspaceChangesSummaryTrailingTask = nil
        workspaceChangesSummaryTrailingTaskID = nil
        workspaceChangesSummaryTrailingDeadline = nil
        let dueWorkspaceIDs = workspaceChangesSummaryTrailingExpiryByWorkspaceID
            .filter { $0.value <= deadline }
            .map(\.key)
            .sorted()
        for workspaceID in dueWorkspaceIDs {
            workspaceChangesSummaryTrailingExpiryByWorkspaceID
                .removeValue(forKey: workspaceID)
        }
        rescheduleWorkspaceChangesSummaryTrailingTask()
        guard !dueWorkspaceIDs.isEmpty else { return }
        scheduleWorkspaceChangesSummaryRefresh(
            workspaceIDs: dueWorkspaceIDs,
            force: false,
            isTrailingPass: true
        )
    }
}
