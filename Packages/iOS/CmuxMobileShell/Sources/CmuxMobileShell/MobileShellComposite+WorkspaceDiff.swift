public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

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
    public func fetchDiffStatus(workspaceID: MobileWorkspacePreview.ID) async throws -> MobileWorkspaceDiffStatusResponse {
        let params = workspaceDiffParams(workspaceID: workspaceID)
        let data = try await sendWorkspaceDiffRequest(
            method: "mobile.workspace.diff_status",
            params: params,
            workspaceID: workspaceID
        )
        return try await Self.decodeWorkspaceDiffResponse {
            try MobileWorkspaceDiffStatusResponse.decode(data)
        }
    }

    /// Fetches a raw unified diff for one file in a workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to review.
    ///   - path: Repository-relative path.
    ///   - oldPath: Previous repository-relative path for a rename.
    ///   - status: Status from the selected changed-file row.
    ///   - repoRoot: Repository root returned by the matching status request.
    /// - Returns: One-file diff payload from the paired Mac.
    public func fetchFileDiff(
        workspaceID: MobileWorkspacePreview.ID,
        path: String,
        oldPath: String?,
        status: String,
        repoRoot: String
    ) async throws -> MobileWorkspaceDiffFileResponse {
        var params = workspaceDiffParams(workspaceID: workspaceID)
        params["path"] = path
        if let oldPath {
            params["old_path"] = oldPath
        }
        params["status"] = status
        params["repo_root"] = repoRoot
        let data = try await sendWorkspaceDiffRequest(
            method: "mobile.workspace.diff_file",
            params: params,
            workspaceID: workspaceID
        )
        return try await Self.decodeWorkspaceDiffResponse {
            try MobileWorkspaceDiffFileResponse.decode(data)
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
            if target.isForeground, !Self.isWorkspaceDiffOperationTimeout(error) {
                markMacConnectionUnavailableIfNeeded(after: error)
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
