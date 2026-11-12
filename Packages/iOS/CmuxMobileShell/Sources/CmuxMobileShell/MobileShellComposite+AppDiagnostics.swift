public import CMUXMobileCore
public import Foundation

public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Records the provider/source metadata for one result made visible to the
    /// task composer. Counts are aggregate metadata only, never model IDs.
    public func recordTaskModelResult(
        provider: MobileTaskAgentProvider,
        correlationID: String?,
        result: MobileTaskModelListResult
    ) {
        let diagnosticProvider: DiagnosticTaskModelProvider = switch provider {
        case .claude: .claude
        case .codex: .codex
        case .openCode: .openCode
        }
        let diagnosticSource: DiagnosticTaskModelSource = switch result.source {
        case .discovered: .discovered
        case .backend: .backend
        case .augmented: .augmented
        case .fallback: .fallback
        }
        var seenModelIDs = Set<String>()
        let effortCount = result.models.reduce(into: 0) { total, model in
            guard seenModelIDs.insert(model.id).inserted else { return }
            total += model.efforts.count
        } + (result.defaultModel.flatMap { seenModelIDs.insert($0.id).inserted ? $0.efforts.count : nil } ?? 0)
        diagnosticLog?.recordTaskModelResult(
            correlationID: correlationID,
            provider: diagnosticProvider,
            source: diagnosticSource,
            effortCount: effortCount
        )
    }

    /// Emits one privacy-safe product event through the app-wide diagnostic spine.
    ///
    /// `correlationID` is reduced to a process-local integer before admission.
    /// Callers must still pass only opaque model identifiers, never user content.
    public func recordAppEvent(
        _ kind: DiagnosticAppEventKind,
        correlationID: String? = nil,
        startedAt: Date? = nil,
        elapsedMilliseconds: UInt32? = nil,
        failure: DiagnosticFailureKind? = nil,
        count: Int? = nil
    ) {
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: correlationID,
            elapsedMilliseconds: elapsedMilliseconds
                ?? startedAt.map { appDiagnosticElapsedMilliseconds(since: $0) },
            failure: failure,
            count: count
        )
    }

    /// Adds one bounded terminal trace phase to the diagnostic spine, carrying
    /// the categorical context that decides whether a slow replay is a blank
    /// screen or merely stale text.
    ///
    /// The trace event has one integer payload slot, and this overload spends
    /// it on ``MobileTerminalReplayTraceContext``. Use it for the phases that
    /// have no byte count to report (`started` and `stalled`); the phases that
    /// carry a payload size keep using `detail`.
    public func recordTerminalTrace(
        operation: DiagnosticTerminalTraceOperation,
        phase: DiagnosticTerminalTracePhase,
        traceID: DiagnosticTerminalTraceID,
        surfaceID: String? = nil,
        startedAt: Date? = nil,
        replayContext: MobileTerminalReplayTraceContext
    ) {
        recordTerminalTrace(
            operation: operation,
            phase: phase,
            traceID: traceID,
            surfaceID: surfaceID,
            startedAt: startedAt,
            detail: replayContext.encoded
        )
    }

    /// Adds one bounded terminal trace phase to the diagnostic spine.
    public func recordTerminalTrace(
        operation: DiagnosticTerminalTraceOperation,
        phase: DiagnosticTerminalTracePhase,
        traceID: DiagnosticTerminalTraceID,
        surfaceID: String? = nil,
        startedAt: Date? = nil,
        detail: Int? = nil
    ) {
        diagnosticLog?.recordTerminalTrace(
            operation: operation,
            phase: phase,
            traceID: traceID,
            surface: DiagnosticCorrelation().handle(for: surfaceID),
            elapsedMilliseconds: startedAt.map { appDiagnosticElapsedMilliseconds(since: $0) },
            detail: detail
        )
    }

    /// Emits one app event with a typed categorical payload.
    public func recordAppEvent(
        _ kind: DiagnosticAppEventKind,
        correlationID: String? = nil,
        startedAt: Date? = nil,
        elapsedMilliseconds: UInt32? = nil,
        failure: DiagnosticFailureKind? = nil,
        detail: DiagnosticAppEventDetail
    ) {
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: correlationID,
            elapsedMilliseconds: elapsedMilliseconds
                ?? startedAt.map { appDiagnosticElapsedMilliseconds(since: $0) },
            failure: failure,
            detail: detail
        )
    }

    func appDiagnosticNow() -> Date {
        runtime?.now() ?? Date()
    }

    private func appDiagnosticElapsedMilliseconds(since startedAt: Date) -> UInt32 {
        let seconds = max(0, appDiagnosticNow().timeIntervalSince(startedAt))
        let milliseconds = seconds * 1_000
        return UInt32(clamping: Int(min(milliseconds, Double(UInt32.max))))
    }
}
