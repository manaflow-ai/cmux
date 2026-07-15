public import CMUXMobileCore
internal import CmuxMobileRPC

extension MobileShellComposite {
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
            guard remoteClient === client else { return nil }
            return try MobileTerminalReplayResponse.decode(data).renderGrid
        } catch {
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
        var seenSurfaceIDs: Set<String> = []
        let orderedSurfaceIDs = (selectedSurfaceIDs + remainingSurfaceIDs).filter {
            seenSurfaceIDs.insert($0).inserted
        }
        guard !orderedSurfaceIDs.isEmpty else { return [:] }

        return await withTaskGroup(
            of: (String, MobileTerminalRenderGridFrame?).self,
            returning: [String: MobileTerminalRenderGridFrame].self
        ) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < orderedSurfaceIDs.count else { return }
                let surfaceID = orderedSurfaceIDs[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    let grid = await self?.fetchPaneMapPreviewGrid(
                        remoteWorkspaceID: remoteWorkspaceID,
                        surfaceID: surfaceID
                    )
                    return (surfaceID, grid)
                }
            }

            for _ in 0..<min(4, orderedSurfaceIDs.count) {
                enqueueNext()
            }

            var gridsBySurfaceID: [String: MobileTerminalRenderGridFrame] = [:]
            while let (surfaceID, grid) = await group.next() {
                if let grid {
                    gridsBySurfaceID[surfaceID] = grid
                }
                enqueueNext()
            }
            return gridsBySurfaceID
        }
    }
}
