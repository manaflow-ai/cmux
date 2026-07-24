public import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    private nonisolated static func decodePaneMapPreviewResponse(
        _ data: Data
    ) async throws -> MobileTerminalReplayResponse {
        let decodeTask = Task.detached(priority: Task.currentPriority) { [data] in
            try Task.checkCancellation()
            let payload = try MobileTerminalReplayResponse.decode(data)
            try Task.checkCancellation()
            return payload
        }
        return try await withTaskCancellationHandler {
            try await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    /// Fetches a read-only render-grid snapshot for one pane-map terminal preview.
    ///
    /// This side channel deliberately omits the mobile terminal client and viewport
    /// fields so observing the pane map cannot resize the Mac's shared terminal grid.
    /// It also stays outside the mounted terminal replay lifecycle and its barriers.
    ///
    /// - Parameters:
    ///   - remoteWorkspaceID: The Mac-local workspace identifier expected by RPC.
    ///   - surfaceID: The terminal surface whose render grid should be previewed.
    /// - Returns: The decoded render grid, or `nil` when the request or decode fails.
    public func fetchPaneMapPreviewGrid(
        remoteWorkspaceID: String,
        surfaceID: String
    ) async -> MobileTerminalRenderGridFrame? {
        guard let client = remoteClient else { return nil }

        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.replay",
                params: [
                    "workspace_id": remoteWorkspaceID,
                    "surface_id": surfaceID,
                ]
            )
            let data = try await client.sendRequest(request)
            try Task.checkCancellation()
            guard remoteClient === client else { return nil }
            let payload = try await Self.decodePaneMapPreviewResponse(data)
            try Task.checkCancellation()
            guard remoteClient === client else { return nil }
            let grid = payload.renderGrid
            MobileDebugLog.anchormux(
                "CMUX_PANEMAP preview surface=\(surfaceID) grid=\(grid != nil) gridSurface=\(grid?.surfaceID ?? "nil") spans=\(grid?.rowSpans.count ?? -1) bytes=\(payload.dataBase64?.count ?? 0)"
            )
            return grid
        } catch is CancellationError {
            return nil
        } catch {
            MobileDebugLog.anchormux("CMUX_PANEMAP preview surface=\(surfaceID) error=\(error)")
            return nil
        }
    }

    /// Fetches pane-map previews with at most four replay requests in flight.
    ///
    /// Selected pane tabs are enqueued before the remaining terminal surfaces.
    /// Duplicate identifiers are removed while preserving that priority order.
    ///
    /// - Parameters:
    ///   - remoteWorkspaceID: The Mac-local workspace identifier expected by RPC.
    ///   - selectedSurfaceIDs: Selected terminal tabs, in pane order.
    ///   - remainingSurfaceIDs: Other terminal tabs, in pane and tab order.
    /// - Returns: Successfully decoded render grids keyed by surface identifier.
    public func fetchPaneMapPreviewGrids(
        remoteWorkspaceID: String,
        selectedSurfaceIDs: [String],
        remainingSurfaceIDs: [String]
    ) async -> [String: MobileTerminalRenderGridFrame] {
        await PaneMapPreviewFetcher().fetch(
            selectedSurfaceIDs: selectedSurfaceIDs,
            remainingSurfaceIDs: remainingSurfaceIDs
        ) { [weak self] surfaceID in
            await self?.fetchPaneMapPreviewGrid(
                remoteWorkspaceID: remoteWorkspaceID,
                surfaceID: surfaceID
            )
        }
    }
}
