internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation
internal import OSLog

nonisolated private let terminalViewportLog = Logger(
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
        let reportedGrid = MobileTerminalViewportSize(columns: columns, rows: rows)
        // Track the natural size locally right away so the SwiftUI letterbox
        // follows the reported grid instead of a stale viewport echo.
        reportTerminalViewport(
            workspaceID: workspaceID,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID),
            viewportSize: reportedGrid
        )
        let previousReportedGrid = reportedTerminalViewportSizesBySurfaceID[surfaceID]
        let prearmedReplayBarrierToken = prearmTerminalViewportReplayBarrierIfNeeded(
            surfaceID: surfaceID,
            previousReportedGrid: previousReportedGrid,
            reportedGrid: reportedGrid
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
                    "viewport_generation": Int(clamping: requestGeneration),
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
            reportedTerminalViewportSizesBySurfaceID[surfaceID] = reportedGrid
            let effectiveGrid = MobileTerminalViewportSize(columns: grid.columns, rows: grid.rows)
            let previousGrid = effectiveViewportSizesBySurfaceID[surfaceID]
            effectiveViewportSizesBySurfaceID[surfaceID] = effectiveGrid
            let shouldRequestReplay = previousGrid.map { $0 != effectiveGrid } ?? true
            if shouldRequestReplay,
               hasTerminalOutputSink(surfaceID: surfaceID) {
                let replayBarrierToken: UUID
                if let prearmedToken = prearmedReplayBarrierToken,
                   terminalReplayBarrierTokensBySurfaceID[surfaceID] == prearmedToken {
                    // The pre-ACK barrier owns this resize; everything that
                    // raced the acknowledgement was deferred against it.
                    replayBarrierToken = prearmedToken
                } else {
                    // No prearmed barrier owns this resize (the reported grid
                    // did not change, but the effective grid did). An
                    // unrelated barrier's replay may already be in flight from
                    // before the Mac applied the new grid; reusing its token
                    // would dedupe the post-resize replay against that stale
                    // request. Begin a fresh barrier so the resize always gets
                    // its own authoritative replay.
                    replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
                }
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
        // The generation entry deliberately outlives the surface: it is the
        // monotonic fence that keeps a still-in-flight viewport report from
        // applying after detach and blocks generation reuse across re-attach.
        // Entries are per-connection; resetTerminalOutputTracking() wipes them.
        let clearGeneration = (viewportReportGenerationsBySurfaceID[surfaceID] ?? 0) + 1
        viewportReportGenerationsBySurfaceID[surfaceID] = clearGeneration
        reportedTerminalViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
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
                    "viewport_generation": Int(clamping: clearGeneration),
                ]
            )
            guard let request else { return }
            _ = try? await client.sendRequest(request)
        }
    }

    private func prearmTerminalViewportReplayBarrierIfNeeded(
        surfaceID: String,
        previousReportedGrid: MobileTerminalViewportSize?,
        reportedGrid: MobileTerminalViewportSize
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
        guard previousReportedGrid != reportedGrid else { return nil }
        // beginTerminalReplayBarrier discards this surface's undelivered
        // output queue, rotates its stream token, and cancels any in-flight
        // replay (including the cold-attach replay). Record that loss before
        // arming so a report that later resolves without a resize still
        // replays authoritative state instead of clearing the barrier with
        // the discarded bytes missing or the cancelled replay unreplaced.
        // If the replacement replay exhausts its retries, the barrier is
        // preserved — the same behavior every barrier trigger has — and the
        // next geometry report, pipeline reset, or reconnect re-arms a fresh
        // barrier with a fresh retry budget. Hosts old enough to lack
        // mobile.terminal.viewport still service mobile.terminal.replay
        // (cold attach depends on it), so the replacement replay clears the
        // barrier under version skew.
        let owesReplacementReplay = !(terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle ?? true)
            || terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            || terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil
        let replayBarrierToken = beginTerminalReplayBarrier(surfaceID: surfaceID)
        if owesReplacementReplay {
            terminalReplayBarrierDroppedOutputSurfaceIDs.insert(surfaceID)
        }
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
