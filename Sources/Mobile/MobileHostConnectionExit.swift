import CMUXMobileCore

/// The privacy-safe reason an admitted host connection stopped.
struct MobileHostConnectionExit: Equatable, Sendable {
    /// The local operation that ended the admitted connection.
    let lifecycle: DiagnosticSessionLifecycleKind

    /// The bounded failure category, or ``DiagnosticFailureKind/none`` for an
    /// expected close.
    let failure: DiagnosticFailureKind

    /// Creates a terminal result for one admitted host connection.
    ///
    /// - Parameters:
    ///   - lifecycle: The local operation that ended the connection.
    ///   - failure: The bounded failure category, or ``DiagnosticFailureKind/none``.
    init(
        lifecycle: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) {
        self.lifecycle = lifecycle
        self.failure = failure
    }
}
