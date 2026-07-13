public import CMUXMobileCore
public import Foundation

extension MobileCoreRPCClient {
    /// Fetches the authoritative pane-and-tab topology for one Mac workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    /// - Returns: The decoded workspace layout snapshot.
    /// - Throws: An RPC, transport, or decoding error.
    public func workspaceLayout(workspaceID: String) async throws -> MobileWorkspaceLayout {
        let request = try Self.requestData(
            method: "mobile.workspace.layout",
            params: ["workspace_id": workspaceID]
        )
        let data = try await sendRequest(request)
        return try JSONDecoder().decode(MobileWorkspaceLayout.self, from: data)
    }
}
