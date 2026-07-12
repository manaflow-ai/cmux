internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Whether the connected Mac can produce a working-tree patch for mobile.
    public var supportsMobileDiff: Bool {
        supportedHostCapabilities.contains("mobile.diff.v1")
    }

    /// Loads a workspace patch from the currently connected Mac.
    public func loadMobileDiff(workspaceID: MobileWorkspacePreview.ID) async throws -> MobileDiffDocument {
        guard let client = remoteClient else {
            throw MobileShellConnectionError.connectionClosed
        }
        let remoteID = remoteWorkspaceID(for: workspaceID)
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.diff.load",
            params: [
                "workspace_id": remoteID.rawValue,
                "client_id": clientID,
            ]
        )
        let data = try await client.sendRequest(request)
        return try MobileDiffDocument(decoding: data)
    }

    /// Returns the stable host error code for a failed mobile diff request.
    /// - Parameter error: Error thrown by ``loadMobileDiff(workspaceID:)``.
    /// - Returns: The host's stable code, or `nil` for transport and decoding failures.
    public func mobileDiffLoadErrorCode(for error: any Error) -> String? {
        guard case let MobileShellConnectionError.rpcError(code, _) = error else { return nil }
        return code
    }
}
