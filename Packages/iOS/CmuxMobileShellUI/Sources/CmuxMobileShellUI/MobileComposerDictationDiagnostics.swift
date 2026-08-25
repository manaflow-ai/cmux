#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport

extension ComposerDictationDiagnosticEvent {
    /// The one bridge from composer dictation lifecycle facts into the app
    /// log. Both terminal and chat composers use it, so every support-package
    /// case is exhaustively classified in one compiler-checked switch.
    @MainActor
    func recordAppDiagnostic(
        correlationID: String,
        store: CMUXMobileShellStore
    ) {
        let mapped = appDiagnosticMapping
        store.recordAppEvent(
            mapped.kind,
            correlationID: correlationID,
            failure: mapped.failure
        )
    }

    private var appDiagnosticMapping: (
        kind: DiagnosticAppEventKind,
        failure: DiagnosticFailureKind?
    ) {
        switch self {
        case .startRequested:
            (.dictationStartRequested, nil)
        case .started:
            (.dictationStarted, nil)
        case .stopRequested:
            (.dictationStopRequested, nil)
        case .stopped:
            (.dictationStopped, nil)
        case .cancelled:
            (.dictationCancelled, .cancelled)
        case .unavailable(let reason):
            (.dictationUnavailable, reason.appDiagnosticFailure)
        case .firstResultReceived:
            (.dictationFirstResultReceived, nil)
        case .recognitionFailed:
            (.dictationRecognitionFailed, .unknown)
        case .stopTimedOut:
            (.dictationStopTimedOut, .timedOut)
        }
    }

}

private extension ComposerDictationUnavailabilityReason {
    var appDiagnosticFailure: DiagnosticFailureKind {
        switch self {
        case .permissionDenied:
            .permissionDenied
        case .unsupportedLocale, .recognizerUnavailable, .audioEngineStartFailed:
            .endpointUnavailable
        }
    }
}
#endif
