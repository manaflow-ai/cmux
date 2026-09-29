import CMUXMobileCore

/// A peer dial exhausted its owner's deadline before admission completed.
struct IrxDialTimedOut: DiagnosticFailureProviding {
    var diagnosticFailureKind: DiagnosticFailureKind { .timedOut }
}
