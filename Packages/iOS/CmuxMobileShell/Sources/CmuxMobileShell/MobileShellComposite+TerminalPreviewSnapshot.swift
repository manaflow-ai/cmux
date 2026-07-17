public import CMUXMobileCore
internal import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

/// One-shot preview reads for the workspace map's pane miniatures.
extension MobileShellComposite {
    /// Fetch a styled full-grid snapshot of one surface (`mobile.terminal.replay`).
    ///
    /// Pure read for miniature rendering: no output-sink registration, no
    /// replay barrier, no viewport params (the Mac answers at the surface's
    /// current grid), and the response is returned to the caller instead of
    /// entering the delivery pipeline. `nil` on any failure — a miniature
    /// that cannot load simply renders as a plain pane card.
    public func fetchTerminalPreviewGrid(
        workspaceID: MobileWorkspacePreview.ID,
        surfaceID: String
    ) async -> MobileTerminalRenderGridFrame? {
        guard let client = remoteClient else { return nil }
        let params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: workspaceID).rawValue,
            "surface_id": surfaceID,
        ]
        guard let request = try? MobileCoreRPCClient.requestData(
            method: "mobile.terminal.replay",
            params: params
        ) else { return nil }
        guard let data = try? await client.sendRequest(request) else { return nil }
        let payload = try? MobileTerminalReplayResponse.decode(data)
        guard let grid = payload?.renderGrid, grid.surfaceID == surfaceID else { return nil }
        return grid
    }
}
