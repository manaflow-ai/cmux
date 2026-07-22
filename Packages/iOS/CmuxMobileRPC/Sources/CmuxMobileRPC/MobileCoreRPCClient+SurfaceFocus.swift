import Foundation

extension MobileCoreRPCClient {
    /// Requests that the paired Mac focus one of its workspace surfaces.
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - surfaceID: Mac-local surface identifier.
    /// - Throws: A transport or RPC error when focus cannot be requested.
    public func focusSurface(workspaceID: String, surfaceID: String) async throws {
        let request = try Self.requestData(
            method: "mobile.surface.focus",
            params: ["workspace_id": workspaceID, "surface_id": surfaceID]
        )
        _ = try await sendRequest(request)
    }
}
