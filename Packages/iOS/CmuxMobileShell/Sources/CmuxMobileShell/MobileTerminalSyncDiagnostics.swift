import CMUXMobileCore
internal import CmuxMobileDiagnostics
import Foundation
@MainActor
final class MobileTerminalSyncDiagnostics {
    private let diagnosticLog: DiagnosticLog?
    private let analytics: any AnalyticsEmitting
    private let now: () -> Date
    private var stallMonitor = TerminalRenderStallMonitor()
    private var analyticsLimiter = TerminalDiagnosticsRateLimiter()
    private var livenessLimiter = TerminalDiagnosticsRateLimiter(
        maxEventsPerWindow: 20,
        window: 30 * 60,
        minimumInterval: 10
    )
    private var replayStartedAtBySurface: [UInt32: Date] = [:]
    private var barrierStartedAtBySurface: [UInt32: Date] = [:]
    private var dropCountsBySurfaceGate: [String: UInt64] = [:]
    private var inputHighWaterBytes = 0
    private var inputBatchStartedAt: Date?

    init(
        diagnosticLog: DiagnosticLog?,
        analytics: any AnalyticsEmitting,
        now: @escaping () -> Date = Date.init
    ) {
        self.diagnosticLog = diagnosticLog
        self.analytics = analytics
        self.now = now
    }

    func renderGridDropped(
        surface: UInt32,
        gate: TerminalRenderDropGate,
        droppedFrames: UInt64,
        replayRetryCount: Int,
        barrierFollowUpCount: Int,
        transport: String,
        ackSeqGap: Int? = nil
    ) {
        let timestamp = now()
        let dropKey = "\(surface):\(gate.rawValue)"
        let previousDropCount = dropCountsBySurfaceGate[dropKey] ?? 0
        let sampleCount = droppedFrames > previousDropCount ? droppedFrames : previousDropCount + 1
        dropCountsBySurfaceGate[dropKey] = sampleCount
        if TerminalDiagnosticsRateLimiter.shouldSampleFrameDrop(count: sampleCount) {
            if gate == .baselineWait {
                diagnosticLog?.record(DiagnosticEvent(.baselineWaitStarted, surface: surface))
            }
            diagnosticLog?.record(DiagnosticEvent(
                .renderGridDropped,
                surface: surface,
                a: Int(gate.rawValue)
            ))
        }
        emit(stallMonitor.noteFrameDropped(surface: surface, gate: gate, now: timestamp)) {
            var props: [String: AnalyticsValue] = [
                "replay_retry_count": .int(replayRetryCount), "barrier_followup_count": .int(barrierFollowUpCount),
                "transport": .string(transport), "input_high_water_bytes": .int(inputHighWaterBytes),
            ]
            if let ackSeqGap { props["ack_seq_gap"] = .int(ackSeqGap) }
            return props
        }
    }

    func frameApplied(surface: UInt32, transport: String) {
        emit(stallMonitor.noteFrameApplied(surface: surface, now: now())) {
            ["transport": .string(transport)]
        }
        resetDropCounts(surface: surface)
    }

    func gateResolved(
        surface: UInt32,
        gate: TerminalRenderDropGate,
        how: TerminalStallRecoveryCause,
        transport: String
    ) {
        emit(stallMonitor.noteGateResolved(surface: surface, gate: gate, how: how, now: now())) {
            ["transport": .string(transport)]
        }
        resetDropCount(surface: surface, gate: gate)
    }

    func surfaceResolved(surface: UInt32, how: TerminalStallRecoveryCause, transport: String) {
        emit(stallMonitor.noteSurfaceResolved(surface: surface, how: how, now: now())) {
            ["transport": .string(transport)]
        }
        resetDropCounts(surface: surface)
    }

    func replayRequested(surface: UInt32, trigger: ReplayTrigger) {
        replayStartedAtBySurface[surface] = now()
        diagnosticLog?.record(DiagnosticEvent(
            .replayRequested,
            surface: surface,
            a: trigger.rawValue
        ))
    }

    func replayAcked(surface: UInt32) {
        let latency = latencyMs(from: replayStartedAtBySurface.removeValue(forKey: surface))
        diagnosticLog?.record(DiagnosticEvent(.replayAcked, surface: surface, ms: latency))
    }

    func replayFailed(
        surface: UInt32,
        reason: ReplayFailureReason,
        retryCount: Int,
        willRetry: Bool
    ) {
        let latency = latencyMs(from: replayStartedAtBySurface[surface])
        diagnosticLog?.record(DiagnosticEvent(
            .replayFailed,
            surface: surface,
            ms: latency,
            a: reason.rawValue,
            b: retryCount
        ))
        captureRateLimited("ios_terminal_replay_failed", [
            "reason": .string(reason.analyticsValue),
            "retry_count": .int(retryCount),
            "latency_ms": .int(Int(latency ?? 0)),
            "will_retry": .bool(willRetry),
        ])
    }

    func replayRetryExhausted(
        surface: UInt32,
        trigger: ReplayTrigger,
        attempts: Int,
        followups: Int
    ) {
        diagnosticLog?.record(DiagnosticEvent(
            .replayRetryExhausted,
            surface: surface,
            a: trigger.rawValue,
            b: attempts
        ))
        captureRateLimited("ios_terminal_replay_retry_exhausted", [
            "trigger": .string(trigger.analyticsValue),
            "attempts": .int(attempts),
            "followups": .int(followups),
        ])
    }

    func barrierArmed(surface: UInt32, trigger: ReplayTrigger) {
        barrierStartedAtBySurface[surface] = now()
        diagnosticLog?.record(DiagnosticEvent(
            .replayBarrierArmed,
            surface: surface,
            a: trigger.rawValue
        ))
    }

    func barrierCleared(surface: UInt32, reason: BarrierReason, transport: String) {
        let latency = latencyMs(from: barrierStartedAtBySurface.removeValue(forKey: surface))
        diagnosticLog?.record(DiagnosticEvent(
            .replayBarrierCleared,
            surface: surface,
            ms: latency,
            a: reason.rawValue
        ))
        gateResolved(
            surface: surface,
            gate: .replayBarrier,
            how: reason.stallRecoveryCause,
            transport: transport
        )
    }

    func barrierPreserved(surface: UInt32, reason: BarrierReason) {
        diagnosticLog?.record(DiagnosticEvent(
            .replayBarrierPreserved,
            surface: surface,
            a: reason.rawValue
        ))
    }

    func viewportReportSuperseded(surface: UInt32? = nil) {
        diagnosticLog?.record(DiagnosticEvent(.viewportReportSuperseded, surface: surface))
    }

    func viewportReportCancelled(surface: UInt32? = nil) {
        diagnosticLog?.record(DiagnosticEvent(
            .viewportReportCancelled,
            surface: surface,
            a: ViewportOutcome.cancelledSuperseded.rawValue
        ))
    }

    func viewportEchoStale(surface: UInt32? = nil) {
        diagnosticLog?.record(DiagnosticEvent(
            .viewportEchoStale,
            surface: surface,
            a: ViewportOutcome.staleEchoRejected.rawValue
        ))
        captureViewportOutcome(.staleEchoRejected)
    }

    func viewportBarrierOutcome(_ outcome: ViewportOutcome, surface: UInt32, count: Int? = nil) {
        let code: DiagnosticEventCode
        switch outcome {
        case .leakedPreserved:
            code = .viewportBarrierLeakedPreserved
        case .rearmExhausted:
            code = .viewportBarrierRearmExhausted
        case .cancelledSuperseded:
            code = .viewportReportCancelled
        case .staleEchoRejected:
            code = .viewportEchoStale
        }
        diagnosticLog?.record(DiagnosticEvent(code, surface: surface, a: outcome.rawValue, b: count))
        captureViewportOutcome(outcome, count: count)
    }

    func livenessProbe(result: LivenessResult, silentMs: Int) {
        diagnosticLog?.record(DiagnosticEvent(
            .livenessProbe,
            ms: UInt32(clamping: silentMs),
            a: result.rawValue
        ))
        guard livenessLimiter.shouldAllow(key: "ios_terminal_liveness_probe", now: now()) else { return }
        analytics.capture("ios_terminal_liveness_probe", [
            "result": .string(result.analyticsValue),
            "silent_ms": .int(silentMs),
        ])
    }

    func resyncTriggered(trigger: ResyncTrigger, restartedStream: Bool, surfaceCount: Int) {
        diagnosticLog?.record(DiagnosticEvent(
            .resyncTriggered,
            a: trigger.rawValue,
            b: restartedStream ? 1 : 0,
            c: surfaceCount
        ))
        captureRateLimited("ios_terminal_resync", [
            "trigger": .string(trigger.analyticsValue),
            "restarted_stream": .bool(restartedStream),
            "surface_count": .int(surfaceCount),
        ])
    }

    func manualRecoverySnapshot(
        surface: UInt32?,
        action: ManualRecoveryAction,
        gatesActive: Int,
        pendingInputWait: Bool,
        replayInFlight: Bool,
        replayRetryCount: Int,
        secondsSinceLastAppliedFrame: Int,
        watchdogSilentMs: Int,
        transport: String,
        ackSeqGap: Int? = nil
    ) {
        diagnosticLog?.record(DiagnosticEvent(
            .manualRecoverySnapshot,
            surface: surface,
            ms: UInt32(clamping: secondsSinceLastAppliedFrame),
            a: gatesActive,
            b: replayRetryCount,
            c: action.rawValue
        ))
        var props: [String: AnalyticsValue] = [
            "action": .string(action.analyticsValue),
            "gates_active": .int(gatesActive),
            "pending_input_wait": .bool(pendingInputWait),
            "replay_in_flight": .bool(replayInFlight),
            "replay_retry_count": .int(replayRetryCount),
            "seconds_since_last_applied_frame": .int(secondsSinceLastAppliedFrame),
            "watchdog_silent_ms": .int(watchdogSilentMs),
            "transport": .string(transport),
            "input_high_water_bytes": .int(inputHighWaterBytes),
        ]
        if let ackSeqGap { props["ack_seq_gap"] = .int(ackSeqGap) }
        analytics.capture("ios_terminal_manual_recovery", props)
    }

    func secondsSinceLastAppliedFrame(surface: UInt32?) -> Int {
        guard let surface else { return 0 }
        let age = stallMonitor.secondsSinceLastAppliedFrame(surface: surface, now: now()) ?? 0
        return Int(max(0, min(age, Double(Int.max))))
    }

    func inputEnqueued(pendingBytes: Int) {
        if inputBatchStartedAt == nil {
            inputBatchStartedAt = now()
        }
        guard pendingBytes > inputHighWaterBytes else { return }
        inputHighWaterBytes = pendingBytes
        diagnosticLog?.record(DiagnosticEvent(.inputSendBufferHighWater, a: pendingBytes))
    }

    func inputDrained() {
        let latency = latencyMs(from: inputBatchStartedAt)
        inputBatchStartedAt = nil
        guard let latency else { return }
        diagnosticLog?.record(DiagnosticEvent(.inputDrainLatency, ms: latency))
    }

    func inputDropped(reason: InputDropReason, pendingBytes: Int?) {
        diagnosticLog?.record(DiagnosticEvent(
            .inputDropped,
            a: reason.rawValue,
            b: pendingBytes
        ))
        var props: [String: AnalyticsValue] = ["reason": .string(reason.analyticsValue)]
        if let pendingBytes { props["pending_byte_count"] = .int(pendingBytes) }
        analytics.capture("ios_terminal_input_dropped", props)
    }

    private func emit(
        _ emissions: [TerminalStallEmission],
        context: () -> [String: AnalyticsValue]
    ) {
        for emission in emissions {
            switch emission {
            case let .stallDetected(surface, gate, droppedFrames, stallDuration):
                diagnosticLog?.record(DiagnosticEvent(
                    .renderStallDetected,
                    surface: surface,
                    ms: UInt32(clamping: Int(stallDuration * 1000)),
                    a: Int(gate.rawValue),
                    b: droppedFrames
                ))
                var props = context()
                props["gate"] = .string(gate.analyticsValue)
                props["dropped_frame_count"] = .int(droppedFrames)
                props["seconds_since_last_applied_frame"] = .double(
                    stallMonitor.secondsSinceLastAppliedFrame(surface: surface, now: now()) ?? stallDuration
                )
                captureRateLimited("ios_terminal_render_stall", props)
            case let .stallRecovered(surface, gate, how, duration, droppedFrames):
                diagnosticLog?.record(DiagnosticEvent(
                    .renderStallRecovered,
                    surface: surface,
                    ms: UInt32(clamping: Int(duration * 1000)),
                    a: Int(gate.rawValue),
                    b: Int(how.rawValue)
                ))
                var props = context()
                props["gate"] = .string(gate.analyticsValue)
                props["recovery"] = .string(how.analyticsValue)
                props["stall_duration_ms"] = .int(Int(duration * 1000))
                props["dropped_frame_count"] = .int(droppedFrames)
                captureRateLimited("ios_terminal_render_stall_recovered", props)
            }
        }
    }

    private func captureViewportOutcome(_ outcome: ViewportOutcome, count: Int? = nil) {
        var props: [String: AnalyticsValue] = ["outcome": .string(outcome.analyticsValue)]
        if let count {
            props["count"] = .int(count)
        }
        captureRateLimited("ios_terminal_viewport_barrier", props)
    }

    private func captureRateLimited(_ event: String, _ props: [String: AnalyticsValue]) {
        guard analyticsLimiter.shouldAllow(key: event, now: now()) else { return }
        analytics.capture(event, props)
    }

    private func latencyMs(from start: Date?) -> UInt32? {
        guard let start else { return nil }
        return UInt32(clamping: Int(max(0, now().timeIntervalSince(start) * 1000)))
    }

    private func resetDropCounts(surface: UInt32) {
        let prefix = "\(surface):"
        dropCountsBySurfaceGate = dropCountsBySurfaceGate.filter { !$0.key.hasPrefix(prefix) }
    }

    private func resetDropCount(surface: UInt32, gate: TerminalRenderDropGate) {
        dropCountsBySurfaceGate.removeValue(forKey: "\(surface):\(gate.rawValue)")
    }
}
