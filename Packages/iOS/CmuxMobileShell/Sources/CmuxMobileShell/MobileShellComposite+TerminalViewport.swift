internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation
internal import OSLog

nonisolated private let terminalViewportLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// A locally committed viewport generation that can be attached to the first
/// replay request before the asynchronous viewport RPC starts.
public struct MobileTerminalViewportPreparation: Sendable {
    fileprivate let workspaceID: MobileWorkspacePreview.ID
    fileprivate let ownerKey: MacPairingKey
    fileprivate let surfaceID: String
    fileprivate let viewportSize: MobileTerminalViewportSize
    fileprivate let generation: UInt64
}

extension MobileShellComposite {
    func terminalViewportGeneration(
        for surfaceID: String,
        ownerKey: MacPairingKey? = nil
    ) -> UInt64? {
        viewportReportGenerationsBySequenceKey[
            MobileTerminalViewportSequenceKey(
                ownerKey: ownerKey ?? foregroundMacKey,
                surfaceID: surfaceID
            )
        ]
    }

    /// Report this device's natural terminal grid to the Mac and return the
    /// effective grid the Mac computed (the smallest across all attached
    /// devices, capped to the Mac pane). The caller pins its libghostty surface
    /// to that grid so every device renders the same cols×rows with a viewport
    /// border around the live area (tmux-style shared resize).
    public func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        guard let preparation = prepareTerminalViewport(
            surfaceID: surfaceID,
            columns: columns,
            rows: rows
        ) else {
            return nil
        }
        return await updatePreparedTerminalViewport(preparation)
    }

    /// Commit the viewport locally before output registration starts.
    ///
    /// Registering an output sink immediately requests a cold replay. Its
    /// request snapshots this cache and generation synchronously, so the Mac
    /// can apply the current phone grid before capturing replay rows.
    public func prepareTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) -> MobileTerminalViewportPreparation? {
        guard columns > 0, rows > 0,
              let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            return nil
        }
        let reportedGrid = MobileTerminalViewportSize(columns: columns, rows: rows)
        // Track the natural size locally right away — even while the Mac
        // connection is still coming up — so cold-attach replays and
        // input/replay piggybacks size against the latest phone grid and the
        // SwiftUI letterbox follows the reported grid instead of a stale
        // viewport echo. Only the RPC below is gated on the client.
        reportTerminalViewport(
            workspaceID: workspaceID,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID),
            viewportSize: reportedGrid
        )
        // Allocate the generation for offline reports too: the cached
        // dimensions above must never ride a piggyback without a generation,
        // or a reordered stale piggyback could overwrite a newer dedicated
        // report after reconnect.
        let ownerKey = foregroundMacKey
        let sequenceKey = MobileTerminalViewportSequenceKey(
            ownerKey: ownerKey,
            surfaceID: surfaceID
        )
        let requestGeneration =
            (viewportReportGenerationsBySequenceKey[sequenceKey] ?? 0) + 1
        viewportReportGenerationsBySequenceKey[sequenceKey] = requestGeneration
        return MobileTerminalViewportPreparation(
            workspaceID: workspaceID,
            ownerKey: ownerKey,
            surfaceID: surfaceID,
            viewportSize: reportedGrid,
            generation: requestGeneration
        )
    }

    /// Send a viewport generation that was committed before output replay was
    /// registered. A newer report or detach invalidates the preparation.
    public func updatePreparedTerminalViewport(
        _ preparation: MobileTerminalViewportPreparation
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        let preparedWorkspaceID = preparation.workspaceID
        let surfaceID = preparation.surfaceID
        let reportedGrid = preparation.viewportSize
        let columns = reportedGrid.columns
        let rows = reportedGrid.rows
        let requestGeneration = preparation.generation
        let sequenceKey = MobileTerminalViewportSequenceKey(
            ownerKey: preparation.ownerKey,
            surfaceID: surfaceID
        )
        let key = MobileTerminalViewportKey(
            workspaceID: preparedWorkspaceID,
            terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
        )
        guard foregroundMacKey == preparation.ownerKey,
              workspaceID(forTerminalID: surfaceID) == preparedWorkspaceID,
              reportedViewportSizesByTerminalKey[key] == reportedGrid,
              viewportReportGenerationsBySequenceKey[sequenceKey] == requestGeneration else {
            recordAppEvent(
                .terminalViewportReportFailed,
                correlationID: surfaceID,
                failure: .superseded
            )
            return nil
        }
        // Demonstration surfaces answer the viewport report locally with the
        // phone's own natural grid: there is no Mac to negotiate with, and a
        // nil answer would put the mounted view into its bounded
        // retryViewportReport loop. Placed before the replay-barrier prearm
        // below so no barrier is ever armed against a demo surface (a
        // lingering barrier would gate the engine's output).
        if demonstrationOwnsSurface(surfaceID) {
            reportedTerminalViewportSizesBySurfaceID[surfaceID] = reportedGrid
            effectiveViewportSizesBySurfaceID[surfaceID] = reportedGrid
            recordAppEvent(
                .terminalViewportReportSucceeded,
                correlationID: surfaceID,
                count: columns * rows
            )
            return (
                columns: columns,
                rows: rows,
                renderEpoch: nil,
                renderRevisionFloor: nil
            )
        }
        guard let client = remoteClient else {
            recordAppEvent(
                .terminalViewportReportFailed,
                correlationID: surfaceID,
                failure: .offline
            )
            return nil
        }
        let previousReportedGrid = reportedTerminalViewportSizesBySurfaceID[surfaceID]
        let prearmedReplayBarrierToken = prearmTerminalViewportReplayBarrierIfNeeded(
            surfaceID: surfaceID,
            previousReportedGrid: previousReportedGrid,
            reportedGrid: reportedGrid
        )
        do {
            let remoteWorkspaceID = remoteWorkspaceID(for: preparedWorkspaceID)
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
                self.recordAppEvent(
                    .terminalViewportReportFailed,
                    correlationID: surfaceID,
                    failure: .superseded
                )
                return nil
            }
            guard viewportReportGenerationsBySequenceKey[sequenceKey] == requestGeneration else {
                // A newer viewport request now owns any pending pre-ACK barrier.
                self.recordAppEvent(
                    .terminalViewportReportFailed,
                    correlationID: surfaceID,
                    failure: .superseded
                )
                return nil
            }
            guard let payload = try? MobileTerminalViewportResponse.decode(data),
                  let grid = payload.effectiveGrid else {
                finishPrearmedTerminalViewportBarrierWithoutResize(
                    surfaceID: surfaceID,
                    token: prearmedReplayBarrierToken,
                    reason: "viewport_missing_grid"
                )
                recordAppEvent(
                    .terminalViewportReportFailed,
                    correlationID: surfaceID,
                    failure: .protocolViolation
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
                    // its own authoritative replay, carrying any replaced
                    // work as owed so an empty replacement cannot clear it.
                    replayBarrierToken = beginTerminalReplayBarrierCarryingReplacedWork(surfaceID: surfaceID)
                }
                terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
                MobileDebugLog.anchormux(
                    "terminal.output.viewport_resync surface=\(surfaceID) grid=\(effectiveGrid.columns)x\(effectiveGrid.rows)"
                )
                requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
            } else if prearmedReplayBarrierToken == nil,
                      terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil,
                      terminalReplayFailureRetryExhausted(surfaceID: surfaceID),
                      hasTerminalOutputSink(surfaceID: surfaceID) {
                // A previous resize replay exhausted its retries and preserved
                // its barrier, and the grid maps already record this geometry
                // as settled — so no later same-size report would otherwise
                // re-arm recovery and output stays dropped. Re-arm with a
                // fresh barrier (fresh retry budget), carrying the preserved
                // barrier's owed work.
                let replayBarrierToken = beginTerminalReplayBarrierCarryingReplacedWork(surfaceID: surfaceID)
                MobileDebugLog.anchormux("terminal.output.viewport_rearm_exhausted surface=\(surfaceID)")
                requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
            } else {
                finishPrearmedTerminalViewportBarrierWithoutResize(
                    surfaceID: surfaceID,
                    token: prearmedReplayBarrierToken,
                    reason: "viewport_unchanged"
                )
            }
            recordAppEvent(
                .terminalViewportReportSucceeded,
                correlationID: surfaceID,
                count: grid.columns * grid.rows
            )
            return (
                columns: grid.columns,
                rows: grid.rows,
                renderEpoch: payload.renderEpoch,
                renderRevisionFloor: payload.renderRevisionFloor
            )
        } catch {
            guard viewportReportGenerationsBySequenceKey[sequenceKey] == requestGeneration else {
                // A newer viewport request now owns any pending pre-ACK barrier.
                return nil
            }
            if error is CancellationError || Task.isCancelled {
                // The report scheduler cancelled this send because a newer
                // geometry report superseded it, but that report has not
                // bumped the generation yet. The pre-ACK barrier must survive
                // for the superseding report to carry; finishing here would
                // clear it (or replay early) before the newest report owns
                // recovery.
                recordAppEvent(
                    .terminalViewportReportFailed,
                    correlationID: surfaceID,
                    failure: .cancelled
                )
                return nil
            }
            finishPrearmedTerminalViewportBarrierWithoutResize(
                surfaceID: surfaceID,
                token: prearmedReplayBarrierToken,
                reason: "viewport_failed"
            )
            terminalViewportLog.error("viewport report failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            recordAppEvent(
                .terminalViewportReportFailed,
                correlationID: surfaceID,
                failure: DiagnosticFailureKind.classify(error)
            )
            return nil
        }
    }

    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    public func clearTerminalViewport(surfaceID: String) {
        recordAppEvent(.terminalViewportClearStarted, correlationID: surfaceID)
        let workspaceID = workspaceID(forTerminalID: surfaceID)
        // A clear releases the presentation's full local viewport lease. Any
        // replay, input, or paste that races after this point must not carry
        // the released dimensions with the newer clear generation and re-pin
        // the Mac surface.
        if let workspaceID {
            reportedViewportSizesByTerminalKey.removeValue(forKey: MobileTerminalViewportKey(
                workspaceID: workspaceID,
                terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
            ))
        } else {
            // A surface can disappear from the workspace snapshot before its
            // teardown callback runs. There is no route for the clear RPC in
            // that case, so discard any colliding local entries as a last
            // line of defence against a later replay piggyback.
            reportedViewportSizesByTerminalKey = reportedViewportSizesByTerminalKey.filter {
                $0.key.terminalID.rawValue != surfaceID
            }
        }
        // The generation entry deliberately outlives the surface: it is the
        // monotonic fence that keeps a still-in-flight viewport report from
        // applying after detach and blocks generation reuse across re-attach.
        // Warm focus swaps keep the peer connection alive, so its fence must
        // outlive the focused role. The account boundary clears all sequences.
        let sequenceKey = MobileTerminalViewportSequenceKey(
            ownerKey: foregroundMacKey,
            surfaceID: surfaceID
        )
        let clearGeneration =
            (viewportReportGenerationsBySequenceKey[sequenceKey] ?? 0) + 1
        viewportReportGenerationsBySequenceKey[sequenceKey] = clearGeneration
        effectiveViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
        reportedTerminalViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
        guard let client = remoteClient,
              let workspaceID else {
            recordAppEvent(
                .terminalViewportClearFailed,
                correlationID: surfaceID,
                failure: .noRoute
            )
            return
        }
        let id = clientID
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        Task { @MainActor in
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.viewport",
                    params: [
                        "workspace_id": remoteWorkspaceID.rawValue,
                        "surface_id": surfaceID,
                        "client_id": id,
                        "clear": true,
                        "viewport_generation": Int(clamping: clearGeneration),
                    ]
                )
                _ = try await client.sendRequest(request)
                self.recordAppEvent(
                    .terminalViewportClearSucceeded,
                    correlationID: surfaceID
                )
            } catch {
                self.recordAppEvent(
                    .terminalViewportClearFailed,
                    correlationID: surfaceID,
                    failure: DiagnosticFailureKind.classify(error)
                )
            }
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
        // If the replacement replay exhausts its retries, the barrier is
        // preserved — the same behavior every barrier trigger has — and the
        // next geometry report, pipeline reset, or reconnect re-arms a fresh
        // barrier with a fresh retry budget. Hosts old enough to lack
        // mobile.terminal.viewport still service mobile.terminal.replay
        // (cold attach depends on it), so the replacement replay clears the
        // barrier under version skew.
        let replayBarrierToken = beginTerminalReplayBarrierCarryingReplacedWork(surfaceID: surfaceID)
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
