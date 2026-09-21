internal import CMUXMobileCore
internal import Foundation

// MARK: - Live terminal path tracing
//
// Per-event breadcrumbs for the LIVE typing/output path, extending the
// replay/artifact trace spine from #12879 so one exported diagnostic
// timeline explains where a keystroke's time went:
//
//   liveInput  started -> requestSent -> responseReceived -> presented
//              (dispatch)  (lane/RPC ok)  (watermark frame    (echo on
//                                          admitted)           screen)
//   liveFrame  decoded -> applied -> presented, or discarded(reason)
//
// The liveInput trace ID is the input's wire marker; liveFrame uses the
// frame's state sequence plus the surface handle. Elapsed milliseconds are
// measured from dispatch (liveInput) or receipt (liveFrame), so a reader
// can attribute latency to echo production upstream versus phone-side
// queueing, gating, application, or presentation.
//
// Volume control: ordinary sessions keep the default 120-per-minute trace
// cap and sample frames 1-in-8, always recording discards. The explicit
// local diagnosis mode (CMUX_TERMINAL_TRACE_VERBOSE=1 in the launch
// environment, or the cmux.debug.terminalTraceVerbose default) raises the
// cap and traces every frame while a typed input is still unacknowledged,
// which is exactly the window where load-correlated latency lives.
extension MobileShellComposite {
    /// Explicit local diagnosis mode. Read once per process.
    static let terminalLiveTraceVerbose: Bool =
        ProcessInfo.processInfo.environment["CMUX_TERMINAL_TRACE_VERBOSE"] == "1"
            || UserDefaults.standard.bool(forKey: "cmux.debug.terminalTraceVerbose")

    private static let verboseTraceMaximumPerMinute = 2_400
    private static let frameSampleStride: UInt64 = 8
    private static let maximumPendingLiveInputTraces = 64

    /// One-time cap raise for the diagnosis mode, applied on first use so it
    /// follows whichever diagnostic log the composition installed.
    private func applyLiveTraceAdmissionPolicyIfNeeded() {
        guard Self.terminalLiveTraceVerbose,
              !liveTraceAdmissionPolicyApplied else { return }
        liveTraceAdmissionPolicyApplied = true
        diagnosticLog?.setTerminalTraceMaximumPerMinute(Self.verboseTraceMaximumPerMinute)
    }

    /// A marked input batch entered the send path.
    func traceLiveInputDispatched(surfaceID: String, sequence: UInt64) {
        guard sequence != 0, let traceID = DiagnosticTerminalTraceID(rawValue: sequence) else { return }
        applyLiveTraceAdmissionPolicyIfNeeded()
        let now = appDiagnosticNow()
        if liveInputTraceStartsBySequence.count >= Self.maximumPendingLiveInputTraces,
           let oldest = liveInputTraceStartsBySequence.min(by: { $0.value < $1.value }) {
            liveInputTraceStartsBySequence.removeValue(forKey: oldest.key)
        }
        liveInputTraceStartsBySequence[sequence] = now
        recordTerminalTrace(
            operation: .liveInput,
            phase: .started,
            traceID: traceID,
            surfaceID: surfaceID
        )
    }

    /// The send settled: the lane write or RPC succeeded or failed.
    func traceLiveInputSettled(surfaceID: String, sequence: UInt64, failed: Bool) {
        guard sequence != 0, let traceID = DiagnosticTerminalTraceID(rawValue: sequence) else { return }
        let startedAt = liveInputTraceStartsBySequence[sequence]
        if failed {
            liveInputTraceStartsBySequence.removeValue(forKey: sequence)
        }
        recordTerminalTrace(
            operation: .liveInput,
            phase: failed ? .failed : .requestSent,
            traceID: traceID,
            surfaceID: surfaceID,
            startedAt: startedAt
        )
    }

    /// A delivered frame's cumulative watermark acknowledged waiting inputs.
    /// Cumulative semantics: one frame settles every older pending trace.
    func traceLiveInputEchoAcknowledged(surfaceID: String, acknowledgedSequence: UInt64) {
        guard !liveInputTraceStartsBySequence.isEmpty else { return }
        for (sequence, startedAt) in liveInputTraceStartsBySequence
        where sequence <= acknowledgedSequence {
            liveInputTraceStartsBySequence.removeValue(forKey: sequence)
            // Keep the dispatch stamp for the presentation phase below.
            liveInputPresentationStartsBySequence[sequence] = startedAt
            if liveInputPresentationStartsBySequence.count > Self.maximumPendingLiveInputTraces,
               let oldest = liveInputPresentationStartsBySequence.min(by: { $0.value < $1.value }) {
                liveInputPresentationStartsBySequence.removeValue(forKey: oldest.key)
            }
            guard let traceID = DiagnosticTerminalTraceID(rawValue: sequence) else { continue }
            recordTerminalTrace(
                operation: .liveInput,
                phase: .responseReceived,
                traceID: traceID,
                surfaceID: surfaceID,
                startedAt: startedAt
            )
        }
    }

    /// The renderer presented the frame that carried an input's echo:
    /// keystroke-to-visible, end to end.
    func traceLiveInputPresented(surfaceID: String, sequence: UInt64) {
        guard sequence != 0,
              let startedAt = liveInputPresentationStartsBySequence.removeValue(forKey: sequence),
              let traceID = DiagnosticTerminalTraceID(rawValue: sequence) else { return }
        recordTerminalTrace(
            operation: .liveInput,
            phase: .presented,
            traceID: traceID,
            surfaceID: surfaceID,
            startedAt: startedAt
        )
    }

    /// Live pending-input traces are meaningless across a connection
    /// teardown; a replacement connection starts clean.
    func clearLiveTerminalTraces() {
        liveInputTraceStartsBySequence.removeAll()
        liveInputPresentationStartsBySequence.removeAll()
    }

    private var shouldTraceLiveFrames: Bool {
        if Self.terminalLiveTraceVerbose { return true }
        if !liveInputTraceStartsBySequence.isEmpty { return true }
        liveFrameTraceSampleCounter &+= 1
        return liveFrameTraceSampleCounter.isMultiple(of: Self.frameSampleStride)
    }

    /// A live frame passed the gates and was admitted for application.
    func traceLiveFrameAdmitted(surfaceID: String, stateSeq: UInt64) {
        guard shouldTraceLiveFrames,
              let traceID = DiagnosticTerminalTraceID(rawValue: max(1, stateSeq)) else { return }
        applyLiveTraceAdmissionPolicyIfNeeded()
        recordTerminalTrace(
            operation: .liveFrame,
            phase: .decoded,
            traceID: traceID,
            surfaceID: surfaceID
        )
    }

    /// A live frame was refused before painting. Always recorded: discards
    /// are the load-correlated mechanism under investigation.
    func traceLiveFrameDiscarded(
        surfaceID: String,
        stateSeq: UInt64,
        reason: DiagnosticTerminalTraceDiscardReason
    ) {
        guard let traceID = DiagnosticTerminalTraceID(rawValue: max(1, stateSeq)) else { return }
        applyLiveTraceAdmissionPolicyIfNeeded()
        recordTerminalTrace(
            operation: .liveFrame,
            phase: .discarded,
            traceID: traceID,
            surfaceID: surfaceID,
            detail: reason.rawValue
        )
    }

    /// A presented live frame, stamped with receipt-to-present latency.
    func traceLiveFramePresented(
        surfaceID: String,
        stateSeq: UInt64?,
        receivedAtNanos: UInt64
    ) {
        guard shouldTraceLiveFrames,
              let traceID = DiagnosticTerminalTraceID(rawValue: max(1, stateSeq ?? 0)) else { return }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- receivedAtNanos
        let elapsedMilliseconds = UInt32(clamping: elapsedNanos / 1_000_000)
        diagnosticLog?.recordTerminalTrace(
            operation: .liveFrame,
            phase: .presented,
            traceID: traceID,
            surface: DiagnosticCorrelation().handle(for: surfaceID),
            elapsedMilliseconds: elapsedMilliseconds
        )
    }
}
