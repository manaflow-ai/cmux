import CMUXMobileCore
internal import CmuxMobileDiagnostics
import CmuxMobileRPC
import CmuxMobileShellModel
public import Foundation
internal import OSLog

nonisolated private let terminalOutputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Yield a raw PTY byte chunk to the surface stream, if one is attached.
    func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        deliverTerminalOutput(
            TerminalOutputDelivery(bytes: bytes, replaceable: false),
            surfaceID: surfaceID
        )
    }

    func deliverTerminalRenderGrid(_ frame: MobileTerminalRenderGridFrame, surfaceID: String) {
        deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: frame.isReplaceableViewportPatchForMobileDelivery
            ),
            surfaceID: surfaceID
        )
    }

    func deliverAuthoritativeTerminalRenderGrid(
        _ renderGrid: MobileTerminalRenderGridFrame,
        expectedSurfaceID: String? = nil,
        source: String
    ) {
        guard expectedSurfaceID == nil || renderGrid.surfaceID == expectedSurfaceID,
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        if terminalReplayIDsInFlightBySurfaceID[renderGrid.surfaceID] != nil {
            bufferTerminalRenderGridFrameDuringReplay(renderGrid, source: source)
            return
        }
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           deliveredSeq > renderGrid.stateSeq {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale source=\(source) surface=\(renderGrid.surfaceID) delivered=\(deliveredSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        if terminalRenderGridContinuityGapSurfaceIDs.contains(renderGrid.surfaceID) {
            guard renderGrid.full else {
                MobileDebugLog.anchormux(
                    "sync.render_grid_gap_drop_delta source=\(source) surface=\(renderGrid.surfaceID) seq=\(renderGrid.stateSeq)"
                )
                requestTerminalReplay(surfaceID: renderGrid.surfaceID)
                return
            }
            terminalRenderGridContinuityGapSurfaceIDs.remove(renderGrid.surfaceID)
            MobileDebugLog.anchormux(
                "sync.render_grid_gap_full_frame source=\(source) surface=\(renderGrid.surfaceID) seq=\(renderGrid.stateSeq)"
            )
        }
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
        deliverTerminalRenderGrid(renderGrid, surfaceID: renderGrid.surfaceID)
    }

    private func bufferTerminalRenderGridFrameDuringReplay(
        _ renderGrid: MobileTerminalRenderGridFrame,
        source: String
    ) {
        let surfaceID = renderGrid.surfaceID
        var frames = terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] ?? []
        if frames.count >= Self.maxRenderGridFramesBufferedDuringReplay {
            frames.removeFirst()
            terminalRenderGridReplayBufferDroppedSurfaceIDs.insert(surfaceID)
            MobileDebugLog.anchormux("sync.render_grid_replay_buffer_drop_oldest source=\(source) surface=\(surfaceID)")
            terminalOutputLog.warning("render-grid replay buffer dropped oldest frame source=\(source, privacy: .public) surface=\(surfaceID, privacy: .public)")
        }
        frames.append(renderGrid)
        terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] = frames
        MobileDebugLog.anchormux("sync.render_grid_buffered_during_replay source=\(source) surface=\(surfaceID) seq=\(renderGrid.stateSeq)")
    }

    func flushTerminalRenderGridFramesBufferedDuringReplay(
        surfaceID: String,
        replaySeq: UInt64?
    ) {
        let droppedFrames = terminalRenderGridReplayBufferDroppedSurfaceIDs.remove(surfaceID) != nil
        let frames = terminalRenderGridFramesBufferedDuringReplayBySurfaceID.removeValue(forKey: surfaceID) ?? []
        if droppedFrames {
            guard !frames.isEmpty else { return }
            terminalRenderGridContinuityGapSurfaceIDs.insert(surfaceID)
            MobileDebugLog.anchormux("sync.render_grid_replay_buffer_overflow_discard surface=\(surfaceID) frames=\(frames.count)")
            terminalOutputLog.info("discarded overflowed render-grid replay buffer surface=\(surfaceID, privacy: .public) frames=\(frames.count, privacy: .public)")
            requestTerminalReplay(surfaceID: surfaceID)
            return
        }
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return }
        for frame in frames where replaySeq.map({ frame.stateSeq > $0 }) ?? true {
            deliverAuthoritativeTerminalRenderGrid(frame, expectedSurfaceID: surfaceID, source: "buffered_replay")
        }
    }

    @discardableResult
    func discardTerminalRenderGridFramesBufferedDuringReplay(surfaceID: String) -> Int {
        terminalRenderGridReplayBufferDroppedSurfaceIDs.remove(surfaceID)
        let frames = terminalRenderGridFramesBufferedDuringReplayBySurfaceID.removeValue(forKey: surfaceID) ?? []
        guard !frames.isEmpty else { return 0 }
        MobileDebugLog.anchormux("sync.render_grid_replay_buffer_discard surface=\(surfaceID) frames=\(frames.count)")
        terminalOutputLog.info("discarded render-grid replay buffer surface=\(surfaceID, privacy: .public) frames=\(frames.count, privacy: .public)")
        return frames.count
    }

    func markTerminalRenderGridContinuityGapAfterReplayFailure(
        surfaceID: String,
        discardedFrameCount: Int
    ) {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return }
        let hasNoSafeBase = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
        let alreadyGap = terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID)
        guard hasNoSafeBase || discardedFrameCount > 0 || alreadyGap else { return }
        terminalRenderGridContinuityGapSurfaceIDs.insert(surfaceID)
        MobileDebugLog.anchormux(
            "sync.render_grid_gap_after_failed_replay surface=\(surfaceID) discarded=\(discardedFrameCount) noBase=\(hasNoSafeBase)"
        )
    }

    func recoverOrDiscardTerminalRenderGridFramesBufferedDuringReplayFailure(
        surfaceID: String
    ) -> (recovered: Bool, discardedFrameCount: Int) {
        let droppedFrames = terminalRenderGridReplayBufferDroppedSurfaceIDs.remove(surfaceID) != nil
        let frames = terminalRenderGridFramesBufferedDuringReplayBySurfaceID.removeValue(forKey: surfaceID) ?? []
        guard !frames.isEmpty else { return (false, 0) }
        guard hasTerminalOutputSink(surfaceID: surfaceID) else {
            MobileDebugLog.anchormux("sync.render_grid_replay_buffer_discard surface=\(surfaceID) frames=\(frames.count)")
            terminalOutputLog.info("discarded render-grid replay buffer surface=\(surfaceID, privacy: .public) frames=\(frames.count, privacy: .public)")
            return (false, frames.count)
        }
        guard let fullFrameIndex = frames.lastIndex(where: { $0.full }) else {
            MobileDebugLog.anchormux("sync.render_grid_replay_buffer_discard surface=\(surfaceID) frames=\(frames.count)")
            terminalOutputLog.info("discarded render-grid replay buffer surface=\(surfaceID, privacy: .public) frames=\(frames.count, privacy: .public)")
            return (false, frames.count)
        }

        let discardedBeforeFull = frames.distance(from: frames.startIndex, to: fullFrameIndex)
        let framesToRecover = frames[fullFrameIndex...]
        MobileDebugLog.anchormux(
            "sync.render_grid_replay_buffer_recover_full surface=\(surfaceID) recovered=\(framesToRecover.count) discarded=\(discardedBeforeFull) dropped=\(droppedFrames)"
        )
        terminalOutputLog.info(
            "recovered render-grid replay buffer from full frame surface=\(surfaceID, privacy: .public) recovered=\(framesToRecover.count, privacy: .public) discarded=\(discardedBeforeFull, privacy: .public) dropped=\(droppedFrames, privacy: .public)"
        )
        for frame in framesToRecover {
            deliverAuthoritativeTerminalRenderGrid(frame, expectedSurfaceID: surfaceID, source: "failed_replay_buffer")
        }
        return (true, discardedBeforeFull)
    }

    static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    private func deliverTerminalOutput(_ delivery: TerminalOutputDelivery, surfaceID: String) {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else { return }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let immediate {
            continuation.yield(
                MobileTerminalOutputChunk(data: immediate.bytes, streamToken: streamToken)
            )
        }
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        continuation.yield(MobileTerminalOutputChunk(data: next.bytes, streamToken: streamToken))
    }

    /// Cold-attach/self-heal replay. Prefer the Mac's bounded render-grid
    /// snapshot, replacing the local iOS terminal state before live bytes
    /// resume. The VT snapshot and raw byte ring remain fallbacks, but neither
    /// is the target architecture: a byte tail is not a complete screen state
    /// for TUIs, and a VT export is still a replay stream rather than state.
    func requestTerminalReplay(surfaceID: String) {
        guard let client = remoteClient else {
            #if DEBUG
            terminalOutputLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=no_remote_client")
            #endif
            return
        }
        guard let workspaceID = workspaceID(forTerminalID: surfaceID) else {
            #if DEBUG
            terminalOutputLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=workspace_not_found")
            #endif
            return
        }
        guard terminalReplayIDsInFlightBySurfaceID[surfaceID] == nil else {
            #if DEBUG
            terminalOutputLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=in_flight")
            #endif
            return
        }
        let request: Data
        do {
            request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.replay",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                ]
            )
        } catch {
            terminalOutputLog.error("CMUX_REPLAY encode failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        let replayID = UUID()
        terminalReplayIDsInFlightBySurfaceID[surfaceID] = replayID
        Task.detached(priority: .userInitiated) { [weak self, client, request, replayID, surfaceID] in
            do {
                let data = try await client.sendRequest(request)
                await self?.applyTerminalReplayResponse(
                    surfaceID: surfaceID,
                    replayID: replayID,
                    client: client,
                    data: data
                )
            } catch {
                await self?.failTerminalReplayRequest(
                    surfaceID: surfaceID,
                    replayID: replayID,
                    client: client,
                    error: error
                )
            }
        }
    }

    private func applyTerminalReplayResponse(
        surfaceID: String,
        replayID: UUID,
        client: MobileCoreRPCClient,
        data: Data
    ) {
        do {
            let payload = try MobileTerminalReplayResponse.decode(data)
            applyTerminalReplayPayload(
                surfaceID: surfaceID,
                replayID: replayID,
                clientIsCurrent: remoteClient === client,
                payload: payload
            )
        } catch {
            terminalOutputLog.error("CMUX_REPLAY decode failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            finishTerminalReplayRequest(
                surfaceID: surfaceID,
                replayID: replayID,
                replayDidApply: false,
                replaySeqForFlush: nil
            )
        }
    }

    private func applyTerminalReplayPayload(
        surfaceID: String,
        replayID: UUID,
        clientIsCurrent: Bool,
        payload: MobileTerminalReplayResponse
    ) {
        var replaySeqForFlush: UInt64?
        var replayDidApply = false
        defer {
            finishTerminalReplayRequest(
                surfaceID: surfaceID,
                replayID: replayID,
                replayDidApply: replayDidApply,
                replaySeqForFlush: replaySeqForFlush
            )
        }
        do {
            guard terminalReplayIDsInFlightBySurfaceID[surfaceID] == replayID else {
                return
            }
            guard clientIsCurrent else { return }
            let bytes = payload.dataBase64.flatMap { Data(base64Encoded: $0) }
            let snapshotBytes = payload.snapshotBase64.flatMap { Data(base64Encoded: $0) }
            let decodedRenderGrid = payload.renderGrid
            let renderGrid = decodedRenderGrid?.surfaceID == surfaceID ? decodedRenderGrid : nil
            let replaySeq = renderGrid?.stateSeq ?? payload.sequence
            replaySeqForFlush = replaySeq
            #if DEBUG
            let seq = replaySeq ?? 0
            let cols = payload.columns ?? -1
            let rows = payload.rows ?? -1
            terminalOutputLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
            #endif
            if let replaySeq,
               let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID],
               deliveredSeq > replaySeq {
                MobileDebugLog.anchormux("CMUX_REPLAY stale surface=\(surfaceID) delivered=\(deliveredSeq) replay=\(replaySeq)")
                return
            }
            let hasReplayPayload = renderGrid != nil
                || snapshotBytes?.isEmpty == false
                || bytes?.isEmpty == false
            guard hasReplayPayload else {
                MobileDebugLog.anchormux("CMUX_REPLAY empty surface=\(surfaceID)")
                return
            }
            replayDidApply = true
            let deliverBytes: Data?
            if let renderGrid {
                deliverBytes = nil
                MobileDebugLog.anchormux("CMUX_REPLAY render_grid surface=\(surfaceID) spans=\(renderGrid.rowSpans.count) seq=\(renderGrid.stateSeq)")
            } else if let snapshotBytes, !snapshotBytes.isEmpty {
                deliverBytes = Self.terminalSnapshotReplacementBytes(snapshotBytes)
                MobileDebugLog.anchormux("CMUX_REPLAY snapshot surface=\(surfaceID) bytes=\(snapshotBytes.count) seq=\(replaySeq ?? 0)")
            } else {
                deliverBytes = bytes
                MobileDebugLog.anchormux("CMUX_REPLAY raw_tail surface=\(surfaceID) bytes=\(bytes?.count ?? -1) seq=\(replaySeq ?? 0)")
            }
            if let replaySeq {
                markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replaySeq)
            }
            if renderGrid != nil || snapshotBytes?.isEmpty == false {
                terminalRenderGridContinuityGapSurfaceIDs.remove(surfaceID)
            }
            if let renderGrid {
                deliverTerminalRenderGrid(renderGrid, surfaceID: surfaceID)
                return
            }
            guard let deliverBytes, !deliverBytes.isEmpty else {
                return
            }
            deliverTerminalBytes(deliverBytes, surfaceID: surfaceID)
        }
    }

    private func failTerminalReplayRequest(
        surfaceID: String,
        replayID: UUID,
        client: MobileCoreRPCClient,
        error: any Error
    ) {
        terminalOutputLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        finishTerminalReplayRequest(
            surfaceID: surfaceID,
            replayID: replayID,
            replayDidApply: false,
            replaySeqForFlush: nil
        )
        // The replay request is the view-only/foreground-resume path. A
        // definitive auth failure here (after the RPC layer's
        // force-refresh-and-retry already gave up) must drive the re-auth
        // prompt instead of silently leaving a stale frame.
        guard remoteClient === client else { return }
        _ = disconnectForAuthorizationFailureIfNeeded(error)
    }

    private func finishTerminalReplayRequest(
        surfaceID: String,
        replayID: UUID,
        replayDidApply: Bool,
        replaySeqForFlush: UInt64?
    ) {
        guard terminalReplayIDsInFlightBySurfaceID[surfaceID] == replayID else {
            return
        }
        terminalReplayIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        if replayDidApply {
            flushTerminalRenderGridFramesBufferedDuringReplay(
                surfaceID: surfaceID,
                replaySeq: replaySeqForFlush
            )
        } else {
            let recovery = recoverOrDiscardTerminalRenderGridFramesBufferedDuringReplayFailure(
                surfaceID: surfaceID
            )
            guard !recovery.recovered else { return }
            markTerminalRenderGridContinuityGapAfterReplayFailure(
                surfaceID: surfaceID,
                discardedFrameCount: recovery.discardedFrameCount
            )
        }
    }

    #if DEBUG
    @discardableResult
    func debugMarkTerminalReplayInFlightForTesting(surfaceID: String) -> UUID {
        let replayID = UUID()
        terminalReplayIDsInFlightBySurfaceID[surfaceID] = replayID
        return replayID
    }

    func debugCancelTerminalReplayForTesting(surfaceID: String) {
        terminalReplayIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        discardTerminalRenderGridFramesBufferedDuringReplay(surfaceID: surfaceID)
    }

    func debugFailTerminalReplayForTesting(surfaceID: String, replayID: UUID? = nil) {
        if let replayID, terminalReplayIDsInFlightBySurfaceID[surfaceID] != replayID {
            return
        }
        terminalReplayIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        let recovery = recoverOrDiscardTerminalRenderGridFramesBufferedDuringReplayFailure(surfaceID: surfaceID)
        guard !recovery.recovered else { return }
        markTerminalRenderGridContinuityGapAfterReplayFailure(
            surfaceID: surfaceID,
            discardedFrameCount: recovery.discardedFrameCount
        )
    }

    func debugApplyTerminalReplayResponseForTesting(
        surfaceID: String,
        replayID: UUID,
        data: Data
    ) throws {
        let payload = try MobileTerminalReplayResponse.decode(data)
        applyTerminalReplayPayload(
            surfaceID: surfaceID,
            replayID: replayID,
            clientIsCurrent: true,
            payload: payload
        )
    }

    func debugFinishTerminalReplayForTesting(
        surfaceID: String,
        replayID: UUID? = nil,
        replayFrame: MobileTerminalRenderGridFrame
    ) {
        if let replayID, terminalReplayIDsInFlightBySurfaceID[surfaceID] != replayID {
            return
        }
        terminalReplayIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridContinuityGapSurfaceIDs.remove(surfaceID)
        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replayFrame.stateSeq)
        deliverTerminalRenderGrid(replayFrame, surfaceID: surfaceID)
        flushTerminalRenderGridFramesBufferedDuringReplay(
            surfaceID: surfaceID,
            replaySeq: replayFrame.stateSeq
        )
    }
    #endif
}
