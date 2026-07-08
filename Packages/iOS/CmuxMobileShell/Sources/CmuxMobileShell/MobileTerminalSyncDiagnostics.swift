import CMUXMobileCore
internal import CmuxMobileDiagnostics
import Foundation
@MainActor
final class MobileTerminalSyncDiagnostics {
    enum ReplayTrigger: Int, Sendable {
        case coldAttach = 1, barrier = 2, droppedRenderGrid = 3, resync = 4
        case baseline = 5, viewport = 6, pendingInput = 7
        var analyticsValue: String {
            switch self {
            case .coldAttach: "cold_attach"
            case .barrier: "barrier"
            case .droppedRenderGrid: "dropped_render_grid"
            case .resync: "resync"
            case .baseline: "baseline"
            case .viewport: "viewport"
            case .pendingInput: "pending_input"
            }
        }
    }
    enum ReplayFailureReason: Int, Sendable {
        case rpcError = 1, empty = 2, staleSequence = 3, bytesNoSeq = 4
        case notDelivered = 5, pendingInputExhausted = 6, staleClient = 7
        case workspaceNotFound = 8, noRemoteClient = 9
        var analyticsValue: String {
            switch self {
            case .rpcError: "rpc_error"
            case .empty: "empty"
            case .staleSequence: "stale_sequence"
            case .bytesNoSeq: "bytes_no_seq"
            case .notDelivered: "not_delivered"
            case .pendingInputExhausted: "pending_input_exhausted"
            case .staleClient: "stale_client"
            case .workspaceNotFound: "workspace_not_found"
            case .noRemoteClient: "no_remote_client"
            }
        }
    }
    enum BarrierReason: Int, Sendable {
        case replayAck = 1, staleClient = 2, staleSequence = 3
        case pendingInputExhausted = 4, notDelivered = 5, empty = 6, bytesNoSeq = 7
        case viewportMissingGrid = 8, viewportUnchanged = 9, viewportFailed = 10
        case viewportStaleClient = 11, coldAttachFailed = 12, noRemoteClient = 13
        case workspaceNotFound = 14, failed = 15, resetReplayAck = 16
        static func from(_ reason: String) -> BarrierReason {
            switch reason {
            case "stale_client": .staleClient
            case "stale_sequence": .staleSequence
            case "pending_input_exhausted": .pendingInputExhausted
            case "not_delivered": .notDelivered
            case "empty": .empty
            case "bytes_no_seq": .bytesNoSeq
            case "viewport_missing_grid": .viewportMissingGrid
            case "viewport_unchanged": .viewportUnchanged
            case "viewport_failed": .viewportFailed
            case "viewport_stale_client": .viewportStaleClient
            case "cold_attach_failed": .coldAttachFailed
            case "no_remote_client": .noRemoteClient
            case "workspace_not_found": .workspaceNotFound
            case "reset_replay_ack": .resetReplayAck
            default: .failed
            }
        }
    }
    enum ViewportOutcome: Int, Sendable {
        case staleEchoRejected = 1, rearmExhausted = 2
        case leakedPreserved = 3, cancelledSuperseded = 4
        var analyticsValue: String {
            switch self {
            case .staleEchoRejected: "stale_echo_rejected"
            case .rearmExhausted: "rearm_exhausted"
            case .leakedPreserved: "leaked_preserved"
            case .cancelledSuperseded: "cancelled_superseded"
            }
        }
    }
    enum LivenessResult: Int, Sendable {
        case ok = 1, repaired = 2, failedResync = 3
        var analyticsValue: String {
            switch self {
            case .ok: "ok"
            case .repaired: "repaired"
            case .failedResync: "failed_resync"
            }
        }
    }
    enum ResyncTrigger: Int, Sendable {
        case liveness = 1, foreground = 2, networkChange = 3
        case manual = 4, inputSeqBehind = 5, streamEnded = 6, other = 7
        var analyticsValue: String {
            switch self {
            case .liveness: "liveness"
            case .foreground: "foreground"
            case .networkChange: "network_change"
            case .manual: "manual"
            case .inputSeqBehind: "input_seq_behind"
            case .streamEnded: "stream_ended"
            case .other: "other"
            }
        }

        static func from(reason: String) -> ResyncTrigger {
            if reason == "liveness" { return .liveness }
            if reason == "foreground" { return .foreground }
            if reason.contains("networkRecovery.networkChange") { return .networkChange }
            if reason.contains("networkRecovery.manual") { return .manual }
            if reason == "input_seq_behind" || reason == "seq_gap" { return .inputSeqBehind }
            if reason == "stream_ended" { return .streamEnded }
            return .other
        }
    }

    enum ManualRecoveryAction: Int, Sendable {
        case pullToRefresh = 1, reconnectTap = 2, renderReset = 3

        var analyticsValue: String {
            switch self {
            case .pullToRefresh: "pull_to_refresh"
            case .reconnectTap: "reconnect_tap"
            case .renderReset: "render_reset"
            }
        }
    }

    enum InputDropReason: Int, Sendable {
        case queueFull = 1, nonUTF8 = 2

        var analyticsValue: String {
            switch self {
            case .queueFull: "queue_full"
            case .nonUTF8: "non_utf8"
            }
        }
    }

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

    func gateResolved(surface: UInt32, how: TerminalStallRecoveryCause, transport: String) {
        emit(stallMonitor.noteGateResolved(surface: surface, how: how, now: now())) {
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
        gateResolved(surface: surface, how: .replayAck, transport: transport)
    }

    func barrierPreserved(surface: UInt32, reason: BarrierReason) {
        diagnosticLog?.record(DiagnosticEvent(
            .replayBarrierPreserved,
            surface: surface,
            a: reason.rawValue
        ))
    }

    func baselineWaitStarted(surface: UInt32) {
        diagnosticLog?.record(DiagnosticEvent(.baselineWaitStarted, surface: surface))
    }

    func viewportReportSuperseded(surface: UInt32? = nil) {
        diagnosticLog?.record(DiagnosticEvent(.viewportReportSuperseded, surface: surface))
    }

    func viewportReportCancelled(surface: UInt32? = nil) {
        diagnosticLog?.record(DiagnosticEvent(.viewportReportCancelled, surface: surface))
    }

    func viewportEchoStale(surface: UInt32? = nil) {
        diagnosticLog?.record(DiagnosticEvent(.viewportEchoStale, surface: surface))
        captureViewportOutcome(.staleEchoRejected)
    }

    func viewportBarrierOutcome(_ outcome: ViewportOutcome, surface: UInt32, count: Int? = nil) {
        let code: DiagnosticEventCode
        switch outcome {
        case .leakedPreserved:
            captureViewportOutcome(outcome, count: count)
            return
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
}

extension TerminalRenderDropGate {
    var analyticsValue: String {
        switch self {
        case .pendingInputSeq: "pending_input_seq"
        case .replayBarrier: "replay_barrier"
        case .baselineWait: "baseline_wait"
        case .viewportBarrier: "viewport_barrier"
        }
    }
}

extension TerminalStallRecoveryCause {
    var analyticsValue: String {
        switch self {
        case .catchupFrame: "catchup_frame"
        case .replayAck: "replay_ack"
        case .resync: "resync"
        case .manualRefresh: "manual_refresh"
        case .reconnect: "reconnect"
        case .surfaceDetached: "surface_detached"
        }
    }
}
