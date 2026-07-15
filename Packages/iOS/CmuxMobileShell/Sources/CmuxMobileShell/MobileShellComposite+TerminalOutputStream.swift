public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    private func unregisterTerminalOutput(surfaceID: String, mountToken: UUID) {
        guard terminalOutputMountTokensBySurfaceID[surfaceID] == mountToken else { return }
        cancelTerminalReplayInFlight(surfaceID: surfaceID)
        terminalColdReplayNeedsBarrierUpgradeSurfaceIDs.remove(surfaceID)
        terminalByteContinuationsBySurfaceID.removeValue(forKey: surfaceID)
        terminalOutputMountTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalOutputStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        resetTerminalMutationQueue(surfaceID: surfaceID, remove: true)
        deferredTerminalRenderGridEventsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckStreamTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridEventPreparationTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierPendingPreparationAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierDroppedOutputSurfaceIDs.remove(surfaceID)
        terminalReplayBarrierDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierAckCoveredDroppedOutputCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayFailureRetryCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalReplayBarrierFollowUpCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalColdAttachReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        if let session = terminalScrollSessionsBySurfaceID.removeValue(forKey: surfaceID) {
            session.cancelForUnmount(nextEpoch: advanceTerminalInteractionEpoch(surfaceID: surfaceID))
        }
        effectiveViewportSizesBySurfaceID.removeValue(forKey: surfaceID); reportedTerminalViewportSizesBySurfaceID.removeValue(forKey: surfaceID)
        terminalViewportReplayBarrierPendingAckTokensBySurfaceID.removeValue(forKey: surfaceID)
        // Drop the letterbox dimension cache too: piggybacks attach the
        // current generation to whatever dimensions this cache holds, and
        // after clearTerminalViewport bumps the generation for the clear, a
        // remount's cold replay could otherwise carry these pre-detach
        // dimensions through the Mac's fence and re-pin the cleared surface.
        // The next dedicated report repopulates the cache with fresh geometry.
        if let workspaceID = workspaceID(forTerminalID: surfaceID) {
            reportedViewportSizesByTerminalKey.removeValue(forKey: viewportKey(
                workspaceID: workspaceID,
                terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
            ))
        }
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalPreBarrierDeliveredEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayRequestCountsBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridBaselineReplayBarrierTokensBySurfaceID.removeValue(forKey: surfaceID)
        equalRevisionTerminalRecoveryReplaysBySurfaceID.removeValue(forKey: surfaceID)
        terminalAlternateRenderGridBaselineSurfaceIDs.remove(surfaceID)
        terminalFullReplacementSeqBySurfaceID.removeValue(forKey: surfaceID)
        terminalFullReplacementGenerationBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalInputDroppedRenderGridSurfaceIDs.remove(surfaceID)
        terminalActiveScreenBySurfaceID.removeValue(forKey: surfaceID)
        // Tell the Mac this device is no longer viewing the surface so it can unpin and clear its border.
        clearTerminalViewport(surfaceID: surfaceID)
        // clearTerminalViewport captures the final interaction epoch before
        // scheduling its request. Keep the epoch fence for a same-connection
        // remount; resetTerminalOutputTracking owns connection-lifetime cleanup.
        observedTerminalRenderRevisionsBySurfaceID.removeValue(forKey: surfaceID)
        appliedTerminalRenderRevisionsBySurfaceID.removeValue(forKey: surfaceID)
        acceptedTerminalRenderRevisionsBySurfaceID.removeValue(forKey: surfaceID)
    }

    /// The output byte stream for a terminal surface.
    ///
    /// Obtaining the stream arms a cold-attach replay so the surface catches up
    /// to current state; ending iteration (or cancelling the consuming task)
    /// unregisters the surface and clears its viewport pin on the Mac.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output byte chunks.
    public func terminalOutputStream(surfaceID: String) -> AsyncStream<MobileTerminalOutputChunk> {
        let mountToken = UUID()
        return AsyncStream { continuation in
            registerTerminalOutput(
                surfaceID: surfaceID,
                mountToken: mountToken,
                continuation: continuation
            )
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.unregisterTerminalOutput(
                        surfaceID: surfaceID,
                        mountToken: mountToken
                    )
                }
            }
        }
    }

    func shouldDropRenderGridBehindPendingInput(_ renderGrid: MobileTerminalRenderGridFrame, source: String) -> Bool {
        if source == "replay",
           let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           renderGrid.stateSeq >= pendingSeq { return false }
        guard let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
              renderGrid.stateSeq < pendingSeq else {
            guard pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(renderGrid.surfaceID),
                  !renderGrid.full,
                  !renderGrid.isReplaceableViewportPatchForMobileDelivery else {
                return false
            }
            MobileDebugLog.anchormux("sync.render_grid_wait_replay source=\(source) surface=\(renderGrid.surfaceID) frame=\(renderGrid.stateSeq)")
            if source == "event" {
                requestTerminalReplayAfterDroppedRenderGrid(surfaceID: renderGrid.surfaceID, source: source)
            }
            return true
        }
        pendingTerminalInputDroppedRenderGridSurfaceIDs.insert(renderGrid.surfaceID)
        MobileDebugLog.anchormux("sync.render_grid_wait_input source=\(source) surface=\(renderGrid.surfaceID) frame=\(renderGrid.stateSeq) pending=\(pendingSeq)")
        if source == "event",
           terminalOutputTransport == .hybrid,
           terminalActiveScreenBySurfaceID[renderGrid.surfaceID] == .alternate,
           renderGrid.activeScreen == .primary {
            // The dropped frame may be the only signal that the host left the
            // alternate screen. Hybrid keeps suppressing raw primary bytes
            // while the tracked screen stays alternate, so without a replay
            // the surface can wedge on stale TUI content. Bounded by the
            // replay retry budget.
            requestTerminalReplayAfterDroppedRenderGrid(surfaceID: renderGrid.surfaceID, source: source)
        }
        return true
    }
}
