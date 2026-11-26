internal import CMUXMobileCore
internal import Foundation

/// Emits evidence while a terminal replay is still outstanding.
///
/// Every other terminal trace phase is terminal, so a replay that never
/// settles produces no analytics row at all: the worst stalls, where the
/// surface has been rebuilt blank and only the replay response can repaint
/// it, were exactly the ones Axiom could not see. This probe closes that gap
/// by stamping ``DiagnosticTerminalTracePhase/stalled`` on a bounded schedule
/// while the request is in flight, carrying the elapsed time and the context
/// that says whether the user is looking at a blank terminal.
///
/// The probe is pure telemetry. It never requests, retries, or fails a
/// replay, and cancelling it cannot change delivery behavior.
extension MobileShellComposite {
    /// Elapsed marks, in seconds, at which an outstanding replay is stamped.
    ///
    /// The first mark sits just above the applied-replay p90 so ordinary slow
    /// replays stay quiet, and the last mark sits past the RPC deadline so a
    /// request the deadline failed to bound still reports.
    static let terminalReplayStallProbeMarks: [Duration] = [
        .seconds(2), .seconds(5), .seconds(10), .seconds(20),
        .seconds(35), .seconds(60), .seconds(120), .seconds(300),
    ]

    func armTerminalReplayStallProbe(
        surfaceID: String,
        requestID: UUID,
        traceID: DiagnosticTerminalTraceID,
        startedAt: Date,
        context: MobileTerminalReplayTraceContext
    ) {
        cancelTerminalReplayStallProbe(surfaceID: surfaceID)
        let clock = controlPlaneSchedulingClock
        let marks = Self.terminalReplayStallProbeMarks
        terminalReplayStallProbeTasksBySurfaceID[surfaceID] = Task { @MainActor [weak self] in
            var elapsed: Duration = .zero
            for mark in marks {
                let step = mark - elapsed
                guard step > .zero else { continue }
                do {
                    try await clock.sleep(for: step, tolerance: nil)
                } catch {
                    return
                }
                elapsed = mark
                guard !Task.isCancelled, let self else { return }
                // The request settled (or was replaced) while this slept; the
                // settled phase is the authoritative record from here on.
                guard self.terminalReplayRequestIDsInFlightBySurfaceID[surfaceID] == requestID else {
                    return
                }
                self.recordTerminalTrace(
                    operation: .replay,
                    phase: .stalled,
                    traceID: traceID,
                    surfaceID: surfaceID,
                    startedAt: startedAt,
                    replayContext: context
                )
            }
        }
    }

    func cancelTerminalReplayStallProbe(surfaceID: String) {
        terminalReplayStallProbeTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
    }

    func cancelAllTerminalReplayStallProbes() {
        for task in terminalReplayStallProbeTasksBySurfaceID.values {
            task.cancel()
        }
        terminalReplayStallProbeTasksBySurfaceID = [:]
    }

    /// The categorical context for a replay about to be requested.
    ///
    /// `surfaceIsBlank` reuses the same condition the request uses to decide
    /// whether to ask the Mac for scrollback: the mirror needs hydration, or
    /// no baseline was ever delivered. Both mean nothing survives locally to
    /// paint, so the surface is blank until this replay lands.
    func terminalReplayTraceContext(
        surfaceID: String,
        trigger: MobileTerminalReplayTrigger,
        replayBarrierToken: UUID?
    ) -> MobileTerminalReplayTraceContext {
        MobileTerminalReplayTraceContext(
            trigger: trigger,
            surfaceIsBlank: deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
                || terminalMirrorHydrationNeededSurfaceIDs.contains(surfaceID),
            barrierActive: replayBarrierToken != nil
                || terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil,
            attempt: terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0
        )
    }
}
