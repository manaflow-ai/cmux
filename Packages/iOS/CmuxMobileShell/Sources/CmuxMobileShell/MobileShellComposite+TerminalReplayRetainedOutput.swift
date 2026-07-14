extension MobileShellComposite {
    func retainTerminalReplayBarrierOutput(
        _ delivery: TerminalOutputDelivery,
        surfaceID: String
    ) {
        var retained = terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID]
            ?? TerminalReplayBarrierRetainedOutput()
        retained.append(delivery)
        terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID] = retained
    }

    func markTerminalReplayBarrierRetainedOutputCoveredByFollowUp(surfaceID: String) {
        guard var retained = terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID] else {
            return
        }
        retained.markCoveredByFollowUpReplay()
        terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID] = retained
    }

    func discardTerminalReplayBarrierRetainedOutputCoveredByFollowUp(surfaceID: String) {
        guard var retained = terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID] else {
            return
        }
        retained.discardDeliveriesCoveredByFollowUpReplay()
        terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID] = retained
    }

    /// Releases output that arrived after the final bounded replay snapshot.
    /// Render grids and raw bytes re-enter their authoritative delivery paths
    /// so each sequence is reconciled against the replay's delivered
    /// high-water mark before entering the regular backpressure queue.
    func reconcileTerminalReplayBarrierRetainedOutput(surfaceID: String) {
        guard let retained = terminalReplayBarrierRetainedOutputBySurfaceID.removeValue(
            forKey: surfaceID
        ) else { return }
        for delivery in retained.deliveries {
            if let renderGrid = delivery.renderGridFrame {
                deliverAuthoritativeTerminalRenderGrid(
                    renderGrid,
                    expectedSurfaceID: surfaceID,
                    source: "replay_barrier_retained"
                )
            } else {
                _ = reduceTerminalByteDelivery(
                    delivery,
                    surfaceID: surfaceID,
                    bypassReplayBarrier: true
                )
            }
        }
    }
}
