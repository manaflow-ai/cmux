import CmuxCore
import Foundation

/// Registered only on authenticated Mac connections, after transport authorization.
@MainActor
struct DeviceWorkspaceLayoutRPC {
    let snapshot: @MainActor (UUID) -> DeviceWorkspaceLayoutNode?

    func handle(_ request: MobileHostRPCRequest) -> MobileHostRPCResult? {
        guard request.method == "device.workspace.layout" else { return nil }
        guard let rawID = request.params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: rawID) else {
            return .failure(MobileHostRPCError(code: "invalid_params", message: "Expected workspace_id"))
        }
        // Native pane state belongs to the main actor; this read never selects or resizes it.
        guard let layout = snapshot(workspaceID) else {
            return .failure(MobileHostRPCError(code: "not_found", message: "Workspace layout unavailable"))
        }
        do {
            let data = try JSONEncoder().encode(DeviceWorkspaceLayoutSnapshot(workspaceID: rawID, layout: layout))
            return .ok(try JSONSerialization.jsonObject(with: data))
        } catch {
            return .failure(MobileHostRPCError(code: "internal_error", message: "Could not encode workspace layout"))
        }
    }
}
