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
        let now = runtime?.now() ?? Date()
        let batches = workspaceChangesSummaryFetchPolicy.batches(
            workspaceIDs: workspaceIDs,
            fetchedAtByWorkspaceID: workspaceChangesSummaryFetchedAtByWorkspaceID,
            now: now,
            force: force
        )

        for batch in batches {
            guard !Task.isCancelled,
                  remoteClient === client,
                  connectionState == .connected else { return }
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.workspace.changes.summary",
                    params: ["workspace_ids": batch]
                )
                let data = try await client.sendRequest(request)
                let response = try MobileWorkspaceChangesSummariesResponse.decode(data)
                guard remoteClient === client, connectionState == .connected else { return }

                var chips = workspaceChangeChipsByWorkspaceID
                for summary in response.summaries where !summary.workspaceID.isEmpty {
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
                for workspaceID in batch {
                    workspaceChangesSummaryFetchedAtByWorkspaceID[workspaceID] = now
                }
            } catch {
                MobileDebugLog.anchormux("changes.summary error \(error)")
                guard !Task.isCancelled, remoteClient === client else { return }
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
        }
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
        return try MobileWorkspaceFileDiffResponse.decode(data)
    }

    func scheduleWorkspaceChangesSummaryRefresh(
        workspaceIDs explicitWorkspaceIDs: [String]? = nil,
        force: Bool = false
    ) {
        guard workspaceChangesCapable,
              connectionState == .connected,
              remoteClient != nil else { return }
        let workspaceIDs = explicitWorkspaceIDs ?? foregroundWorkspaceChangesIDs
        guard !workspaceIDs.isEmpty else {
            MobileDebugLog.anchormux("changes.schedule skip: no foreground workspace ids")
            return
        }

        workspaceChangesSummaryRefreshForce = workspaceChangesSummaryRefreshForce || force
        workspaceChangesSummaryRefreshTask?.cancel()
        let taskID = UUID()
        workspaceChangesSummaryRefreshTaskID = taskID
        workspaceChangesSummaryRefreshTask = Task { @MainActor [weak self] in
            // A bounded, cancellable delay is the intended event/list debounce.
            try? await ContinuousClock().sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let shouldForce = self.workspaceChangesSummaryRefreshForce
            self.workspaceChangesSummaryRefreshForce = false
            await self.fetchWorkspaceChangesSummaries(
                workspaceIDs: workspaceIDs,
                force: shouldForce
            )
            self.clearWorkspaceChangesSummaryRefreshTask(id: taskID)
        }
    }

    func resetWorkspaceChangesState() {
        workspaceChangesSummaryRefreshTask?.cancel()
        workspaceChangesSummaryRefreshTask = nil
        workspaceChangesSummaryRefreshTaskID = nil
        workspaceChangesSummaryRefreshForce = false
        workspaceChangesSummaryFetchedAtByWorkspaceID = [:]
        setWorkspaceChangeChipsByWorkspaceID([:])
    }

    private var foregroundWorkspaceChangesIDs: [String] {
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

    private func clearWorkspaceChangesSummaryRefreshTask(id: UUID) {
        guard workspaceChangesSummaryRefreshTaskID == id else { return }
        workspaceChangesSummaryRefreshTask = nil
        workspaceChangesSummaryRefreshTaskID = nil
    }
}
