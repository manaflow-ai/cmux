public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
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
        return try MobileWorkspaceDiffStatusResponse.decode(data)
    }

    /// Fetches a raw unified diff for one file in a workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace to review.
    ///   - path: Repository-relative path.
    /// - Returns: One-file diff payload from the paired Mac.
    public func fetchFileDiff(workspaceID: MobileWorkspacePreview.ID, path: String) async throws -> MobileWorkspaceDiffFileResponse {
        var params = workspaceDiffParams(workspaceID: workspaceID)
        params["path"] = path
        let data = try await sendWorkspaceDiffRequest(
            method: "mobile.workspace.diff_file",
            params: params,
            workspaceID: workspaceID
        )
        return try MobileWorkspaceDiffFileResponse.decode(data)
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
                timeoutNanoseconds: runtime?.pairingRequestTimeoutNanoseconds
            )
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                throw error
            }
            if target.isForeground {
                markMacConnectionUnavailableIfNeeded(after: error)
            }
            throw error
        }
    }
}
