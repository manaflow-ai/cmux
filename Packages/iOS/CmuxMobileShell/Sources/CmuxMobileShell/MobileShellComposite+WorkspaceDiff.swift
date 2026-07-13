public import CmuxDiffModel
public import CmuxMobileShellModel
internal import Foundation
internal import CmuxMobileRPC

extension MobileShellComposite {
    private static let workspaceDiffCapability = "workspace.diff.v1"

    /// Whether the Mac that owns `workspaceID` advertises native diff review
    /// (`workspace.diff.v1`). Checked per workspace because the diff RPCs route
    /// to the owning Mac (foreground or secondary), whose capability set can
    /// differ from the foreground's.
    public func supportsDiffReview(for workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.isDiffReviewEligible else { return false }
        let owner = workspace.macDeviceID
        if owner == nil || owner == foregroundMacDeviceID || owner == Self.foregroundAnonymousKey {
            return supportedHostCapabilities.contains(Self.workspaceDiffCapability)
        }
        if let owner, let subscription = secondaryMacSubscriptions[owner] {
            return subscription.supportedHostCapabilities.contains(Self.workspaceDiffCapability)
        }
        return false
    }

    /// Fetches changed files for a workspace's current git repository.
    ///
    /// - Parameter workspaceID: The workspace to review.
    /// - Returns: Diff status payload from the paired Mac.
    public func fetchDiffStatus(workspaceID: MobileWorkspacePreview.ID) async throws -> DiffStatusSnapshot {
        do {
            let params = workspaceDiffParams(workspaceID: workspaceID)
            let data = try await sendWorkspaceDiffRequest(
                method: "mobile.workspace.diff_status",
                params: params,
                workspaceID: workspaceID
            )
            return try await Self.decodeWorkspaceDiffResponse {
                try Self.decodeDiffStatusSnapshot(data)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.workspaceDiffError(from: error)
        }
    }

    /// Fetches a raw unified diff for one file in a workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to review.
    ///   - file: Selected changed-file row and its repository-state identity.
    ///   - repoRoot: Repository root returned by the matching status request.
    /// - Returns: One-file diff payload from the paired Mac.
    public func fetchFileDiff(
        workspaceID: MobileWorkspacePreview.ID,
        file: DiffFileSummary,
        repoRoot: String
    ) async throws -> DiffFilePatch {
        do {
            var params = workspaceDiffParams(workspaceID: workspaceID)
            params["path"] = file.path
            if let oldPath = file.oldPath {
                params["old_path"] = oldPath
            }
            params["status"] = file.status.rawValue
            if let additions = file.additions {
                params["additions"] = additions
            }
            if let deletions = file.deletions {
                params["deletions"] = deletions
            }
            params["snapshot_token"] = file.snapshotToken
            params["repo_root"] = repoRoot
            let data = try await sendWorkspaceDiffRequest(
                method: "mobile.workspace.diff_file",
                params: params,
                workspaceID: workspaceID
            )
            return try await Self.decodeWorkspaceDiffResponse {
                try Self.decodeDiffFilePatch(data, expectedPath: file.path)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.workspaceDiffError(from: error)
        }
    }

    nonisolated static func decodeDiffStatusSnapshot(_ data: Data) throws -> DiffStatusSnapshot {
        let response = try MobileWorkspaceDiffStatusResponse.decode(data)
        let files = try response.files.map { file in
            guard let status = DiffFileStatus(rawValue: file.status) else {
                throw WorkspaceDiffError.unavailable
            }
            return DiffFileSummary(
                path: file.path,
                oldPath: file.oldPath,
                status: status,
                additions: file.additions,
                deletions: file.deletions,
                snapshotToken: file.snapshotToken
            )
        }
        return DiffStatusSnapshot(
            repoRoot: response.repoRoot,
            files: files,
            isTruncated: response.truncated
        )
    }

    nonisolated static func decodeDiffFilePatch(_ data: Data, expectedPath: String) throws -> DiffFilePatch {
        let response = try MobileWorkspaceDiffFileResponse.decode(data)
        guard response.path == expectedPath else { throw WorkspaceDiffError.unavailable }
        return DiffFilePatch(
            path: response.path,
            unifiedDiff: response.unifiedDiff,
            isTruncated: response.truncated
        )
    }

    nonisolated static func workspaceDiffError(from error: any Error) -> WorkspaceDiffError {
        if let diffError = error as? WorkspaceDiffError {
            return diffError
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return .unavailable
        }
        switch connectionError {
        case .requestTimedOut:
            return .timedOut
        case .rpcError(let code, _):
            switch code {
            case "not_found":
                return .notFound
            case "git_failed":
                return .gitFailed
            case "git_timeout":
                return .timedOut
            case "stale_repository":
                return .staleRepository
            default:
                return .unavailable
            }
        default:
            return .unavailable
        }
    }

    /// Keep bounded but substantial JSON unescaping and DTO construction off
    /// the main actor. Cancellation discards a stale result at both boundaries.
    nonisolated static func decodeWorkspaceDiffResponse<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func workspaceDiffParams(workspaceID: MobileWorkspacePreview.ID) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: workspaceID).rawValue,
            "client_id": clientID,
        ]
        if let windowID = workspaces.first(where: { $0.id == workspaceID })?.windowID {
            params["window_id"] = windowID
        }
        return params
    }

    private func sendWorkspaceDiffRequest(
        method: String,
        params: [String: Any],
        workspaceID: MobileWorkspacePreview.ID
    ) async throws -> Data {
        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else {
            throw MobileShellConnectionError.connectionClosed
        }
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            return try await client.sendRequest(
                request,
                timeoutNanoseconds: runtime?.rpcRequestTimeoutNanoseconds
            )
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error, target: target) else {
                throw error
            }
            if !Self.isWorkspaceDiffOperationTimeout(error) {
                markMacConnectionUnavailableIfNeeded(after: error, target: target)
            }
            throw error
        }
    }

    /// A diff can exhaust its operation deadline while the Mac and transport
    /// remain healthy. Connection-closed and network failures still flow into
    /// the normal foreground availability classifier.
    private static func isWorkspaceDiffOperationTimeout(_ error: any Error) -> Bool {
        guard let shellError = error as? MobileShellConnectionError else { return false }
        if case .requestTimedOut = shellError { return true }
        return false
    }
}
