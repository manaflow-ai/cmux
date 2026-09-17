public import CMUXMobileCore
public import Foundation

extension MobileShellComposite {
    /// Emits one privacy-safe product event through the app-wide diagnostic spine.
    ///
    /// `correlationID` is reduced to a process-local integer before admission.
    /// Callers must still pass only opaque model identifiers, never user content.
    public func recordAppEvent(
        _ kind: DiagnosticAppEventKind,
        correlationID: String? = nil,
        startedAt: Date? = nil,
        failure: DiagnosticFailureKind? = nil,
        count: Int? = nil
    ) {
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: correlationID,
            elapsedMilliseconds: startedAt.map { appDiagnosticElapsedMilliseconds(since: $0) },
            failure: failure,
            count: count
        )
    }

    /// Emits one app event with a typed categorical payload.
    public func recordAppEvent(
        _ kind: DiagnosticAppEventKind,
        correlationID: String? = nil,
        startedAt: Date? = nil,
        failure: DiagnosticFailureKind? = nil,
        detail: DiagnosticAppEventDetail
    ) {
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: correlationID,
            elapsedMilliseconds: startedAt.map { appDiagnosticElapsedMilliseconds(since: $0) },
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
