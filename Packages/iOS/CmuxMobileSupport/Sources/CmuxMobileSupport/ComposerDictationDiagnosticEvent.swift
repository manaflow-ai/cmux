/// Privacy-safe lifecycle facts emitted by ``ComposerDictationController``.
///
/// The event stream deliberately contains no recognized text, locale, device
/// name, or raw system error. App surfaces can bridge these fixed cases into
/// their durable diagnostic log without giving the support package a logging
/// dependency.
public enum ComposerDictationDiagnosticEvent: Sendable, Equatable {
    case startRequested
    case started
    case stopRequested
    case stopped
    case cancelled
    case unavailable(ComposerDictationUnavailabilityReason)
    case firstResultReceived
    case recognitionFailed
    case stopTimedOut
}

/// Fixed reason a dictation start could not become a listening session.
public enum ComposerDictationUnavailabilityReason: Int, Sendable, Equatable {
    case unsupportedLocale = 1
    case permissionDenied = 2
    case recognizerUnavailable = 3
    case audioEngineStartFailed = 4
}
