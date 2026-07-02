internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let terminalViewportLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Report this device's natural terminal grid to the Mac and return the
    /// effective grid the Mac computed (the smallest across all attached
    /// devices, capped to the Mac pane). The caller pins its libghostty surface
    /// to that grid so every device renders the same cols×rows with a viewport
    /// border around the live area (tmux-style shared resize).
    public func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (columns: Int, rows: Int)? {
        guard columns > 0, rows > 0,
              let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return nil
        }
        let previousGridBeforeRequest = effectiveViewportSizesBySurfaceID[surfaceID]
        let prearmedReplayBarrierToken = prearmTerminalViewportReplayBarrierIfNeeded(
            surfaceID: surfaceID,
            previousGrid: previousGridBeforeRequest,
            columns: columns,
            rows: rows
        )
        let requestGeneration = (viewportReportGenerationsBySurfaceID[surfaceID] ?? 0) + 1
        viewportReportGenerationsBySurfaceID[surfaceID] = requestGeneration
        do {
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": remoteWorkspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "viewport_columns": columns,
                    "viewport_rows": rows,
                ]
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else {
                clearTerminalReplayBarrierIfCurrent(
                    surfaceID: surfaceID,
                    token: prearmedReplayBarrierToken,
                    reason: "viewport_stale_client"
                )
                return nil
            }
            guard viewportReportGenerationsBySurfaceID[surfaceID] == requestGeneration else {
                // A newer viewport request now owns any pending pre-ACK barrier.
                return nil
            }
            guard let payload = try? MobileTerminalViewportResponse.decode(data),
                  let grid = payload.effectiveGrid else {
                finishPrearmedTerminalViewportBarrierWithoutResize(
                    surfaceID: surfaceID,
                    token: prearmedReplayBarrierToken,
                    reason: "viewport_missing_grid"
                )
                return nil
            }
            let effectiveGrid = MobileTerminalViewportSize(columns: grid.columns, rows: grid.rows)
            let previousGrid = effectiveViewportSizesBySurfaceID[surfaceID]
            effectiveViewportSizesBySurfaceID[surfaceID] = effectiveGrid
            let shouldRequestReplay = previousGrid.map { $0 != effectiveGrid } ?? true
            if shouldRequestReplay,
               hasTerminalOutputSink(surfaceID: surfaceID) {
                let replayBarrierToken = prearmedReplayBarrierToken
                    ?? beginTerminalReplayBarrier(surfaceID: surfaceID)
                terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
                MobileDebugLog.anchormux(
                    "terminal.output.viewport_resync surface=\(surfaceID) grid=\(effectiveGrid.columns)x\(effectiveGrid.rows)"
                )
                requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
            } else {
                finishPrearmedTerminalViewportBarrierWithoutResize(
                    surfaceID: surfaceID,
                    token: prearmedReplayBarrierToken,
                    reason: "viewport_unchanged"
                )
            }
            return (grid.columns, grid.rows)
        } catch {
            guard viewportReportGenerationsBySurfaceID[surfaceID] == requestGeneration else {
                // A newer viewport request now owns any pending pre-ACK barrier.
                return nil
            }
            finishPrearmedTerminalViewportBarrierWithoutResize(
                surfaceID: surfaceID,
                token: prearmedReplayBarrierToken,
                reason: "viewport_failed"
            )
            terminalViewportLog.error("viewport report failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    public func clearTerminalViewport(surfaceID: String) {
        viewportReportGenerationsBySurfaceID[surfaceID, default: 0] += 1
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return
        }
        let id = clientID
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        Task { @MainActor in
            let request = try? MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": remoteWorkspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": id,
                    "clear": true,
                ]
            )
            guard let request else { return }
            _ = try? await client.sendRequest(request)
        }
    }

    private func prearmTerminalViewportReplayBarrierIfNeeded(
        surfaceID: String,
        previousGrid: MobileTerminalViewportSize?,
        columns: Int,
        rows: Int
    ) -> UUID? {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return nil }
        if let pendingToken = terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] {
            // Rapid geometry reversals must carry the existing drop barrier
            // forward even when the latest report matches the last effective grid.
            if terminalReplayBarrierTokensBySurfaceID[surfaceID] == pendingToken {
                return pendingToken
            }
            terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        }
        guard previousGrid.map({ $0.columns != columns || $0.rows != rows }) ?? true else {
            return nil
        }
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] = replayBarrierToken
        return replayBarrierToken
    }

    private func finishPrearmedTerminalViewportBarrierWithoutResize(
        surfaceID: String,
        token: UUID?,
        reason: String
    ) {
        guard let token else { return }
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        guard terminalReplayBarrierTokensBySurfaceID[surfaceID] == token else { return }
        if terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID),
           hasTerminalOutputSink(surfaceID: surfaceID),
           remoteClient != nil {
            MobileDebugLog.anchormux("terminal.output.viewport_replay_after_\(reason) surface=\(surfaceID)")
            requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: token)
            return
        }
        clearTerminalReplayBarrierIfCurrent(
            surfaceID: surfaceID,
            token: token,
            reason: reason
        )
    }
}
