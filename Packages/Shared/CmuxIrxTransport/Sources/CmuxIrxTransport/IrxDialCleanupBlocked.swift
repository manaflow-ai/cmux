import CMUXMobileCore

/// Native dial capacity is held by work that has not physically finished cleanup.
struct IrxDialCleanupBlocked: DiagnosticFailureProviding {
    var diagnosticFailureKind: DiagnosticFailureKind { .admissionDenied }
}
