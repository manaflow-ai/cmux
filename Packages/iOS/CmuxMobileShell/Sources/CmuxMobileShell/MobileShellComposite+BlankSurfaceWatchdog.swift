internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import Foundation

/// Reports a mounted surface that is blank with nothing working to fill it.
///
/// Every other terminal trace observes a replay that is *in flight*. The
/// failure this exists for is the opposite: the surface stopped asking. Once
/// the retry budget is spent the barrier fails open, live output resumes, and
/// nothing re-requests a replay. A terminal that is actively printing paints
/// over the gap and nobody notices; an idle one stays blank until new output,
/// a remount, or an app relaunch. That state produced no telemetry at all, so
/// the exact moment a user is staring at an empty terminal was the moment
/// Axiom went quiet.
///
/// Pure telemetry. Arming, firing and cancelling this changes no delivery
/// behavior; it only observes state the shell already holds.
extension MobileShellComposite {
    /// Elapsed marks at which an unattended blank surface is re-reported.
    ///
    /// The first mark is comfortably past a normal replay round trip, so an
    /// ordinary repaint never registers.
    static let blankSurfaceWatchdogMarks: [Duration] = [
        .seconds(3), .seconds(10), .seconds(30), .seconds(120),
    ]

    /// Whether a surface is blank with nothing outstanding to repair it.
    ///
    /// All three conditions matter. Blank alone is normal while a replay is
    /// on its way, and an in-flight replay or a raised barrier both mean
    /// something is already working on it.
    func terminalSurfaceIsUnattendedBlank(surfaceID: String) -> Bool {
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return false }
        guard deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
            || terminalMirrorHydrationNeededSurfaceIDs.contains(surfaceID) else { return false }
        guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else { return false }
        return terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }

    /// Records why this surface most recently stopped asking for content, so
    /// the blank report can say what abandoned it rather than only that it is
    /// empty.
    func recordTerminalSurfaceGaveUp(
        surfaceID: String,
        trigger: MobileTerminalReplayTrigger
    ) {
        terminalSurfaceGaveUpTriggersBySurfaceID[surfaceID] = trigger
        evaluateTerminalBlankSurfaceWatchdog(surfaceID: surfaceID)
    }

    /// Opens, keeps, or closes the blank report for one surface.
    ///
    /// Safe to call from any state transition that could start or end the
    /// unattended-blank condition; it reconciles rather than assuming.
    func evaluateTerminalBlankSurfaceWatchdog(surfaceID: String) {
        guard terminalSurfaceIsUnattendedBlank(surfaceID: surfaceID) else {
            // `applied` only when content actually arrived. A replay taking
            // over ends this condition without ending the blank, and calling
            // that a success would report a repaint that never happened.
            let painted = hasTerminalOutputSink(surfaceID: surfaceID)
                && deliveredTerminalByteEndSeqBySurfaceID[surfaceID] != nil
                && !terminalMirrorHydrationNeededSurfaceIDs.contains(surfaceID)
            resolveTerminalBlankSurfaceWatchdog(
                surfaceID: surfaceID,
                phase: painted ? .applied : .discarded
            )
            return
        }
        guard terminalBlankSurfaceWatchdogTasksBySurfaceID[surfaceID] == nil else { return }

        let traceID = DiagnosticTerminalTraceID()
        let startedAt = appDiagnosticNow()
        let context = MobileTerminalReplayTraceContext(
            trigger: terminalSurfaceGaveUpTriggersBySurfaceID[surfaceID] ?? .unknown,
            surfaceIsBlank: true,
            barrierActive: false,
            attempt: terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0,
            replayInFlight: false,
            retryExhausted: terminalReplayFailureRetryExhausted(surfaceID: surfaceID),
            isConnected: connectionState == .connected,
            terminalEventAgeSeconds: terminalEventAgeSecondsForDiagnostics()
        )
        terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] = traceID
        terminalBlankSurfaceWatchdogStartedAtBySurfaceID[surfaceID] = startedAt
        terminalBlankSurfaceWatchdogContextsBySurfaceID[surfaceID] = context
        recordTerminalTrace(
            operation: .blankSurface,
            phase: .started,
            traceID: traceID,
            surfaceID: surfaceID,
            replayContext: context
        )
        MobileDebugLog.anchormux(
            "terminal.surface.unattended_blank surface=\(surfaceID) trigger=\(context.trigger)"
        )

        let clock = controlPlaneSchedulingClock
        let marks = Self.blankSurfaceWatchdogMarks
        terminalBlankSurfaceWatchdogTasksBySurfaceID[surfaceID] = Task { @MainActor [weak self] in
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
                guard !Task.isCancelled, let self,
                      self.terminalBlankSurfaceWatchdogTraceIDsBySurfaceID[surfaceID] == traceID,
                      self.terminalSurfaceIsUnattendedBlank(surfaceID: surfaceID) else { return }
                // Re-read rather than reusing the opening snapshot: the lane
                // or the connection can recover while the surface stays
                // blank, and that difference is the whole diagnosis.
                self.recordTerminalTrace(
                    operation: .blankSurface,
                    phase: .stalled,
                    traceID: traceID,
                    surfaceID: surfaceID,
                    startedAt: startedAt,
                    replayContext: MobileTerminalReplayTraceContext(
                        trigger: context.trigger,
                        surfaceIsBlank: true,
                        barrierActive: false,
                        attempt: self.terminalReplayFailureRetryCountsBySurfaceID[surfaceID] ?? 0,
                        replayInFlight: false,
                        retryExhausted: self.terminalReplayFailureRetryExhausted(
                            surfaceID: surfaceID
                        ),
                        isConnected: self.connectionState == .connected,
                        terminalEventAgeSeconds: self.terminalEventAgeSecondsForDiagnostics()
                    )
                )
            }
        }
    }

    /// Closes an open blank report. `applied` means content finally arrived;
    /// `discarded` means the surface went away before it did.
    func resolveTerminalBlankSurfaceWatchdog(
        surfaceID: String,
        phase: DiagnosticTerminalTracePhase
    ) {
        terminalBlankSurfaceWatchdogTasksBySurfaceID.removeValue(forKey: surfaceID)?.cancel()
        guard let traceID = terminalBlankSurfaceWatchdogTraceIDsBySurfaceID
            .removeValue(forKey: surfaceID) else {
            terminalBlankSurfaceWatchdogStartedAtBySurfaceID.removeValue(forKey: surfaceID)
            terminalBlankSurfaceWatchdogContextsBySurfaceID.removeValue(forKey: surfaceID)
            return
        }
        let startedAt = terminalBlankSurfaceWatchdogStartedAtBySurfaceID
            .removeValue(forKey: surfaceID)
        let context = terminalBlankSurfaceWatchdogContextsBySurfaceID
            .removeValue(forKey: surfaceID)
        recordTerminalTrace(
            operation: .blankSurface,
            phase: phase,
            traceID: traceID,
            surfaceID: surfaceID,
            startedAt: startedAt,
            detail: context?.encoded
        )
    }

    func cancelAllTerminalBlankSurfaceWatchdogs() {
        for task in terminalBlankSurfaceWatchdogTasksBySurfaceID.values { task.cancel() }
        terminalBlankSurfaceWatchdogTasksBySurfaceID = [:]
        terminalBlankSurfaceWatchdogTraceIDsBySurfaceID = [:]
        terminalBlankSurfaceWatchdogStartedAtBySurfaceID = [:]
        terminalBlankSurfaceWatchdogContextsBySurfaceID = [:]
        terminalSurfaceGaveUpTriggersBySurfaceID = [:]
    }
}
