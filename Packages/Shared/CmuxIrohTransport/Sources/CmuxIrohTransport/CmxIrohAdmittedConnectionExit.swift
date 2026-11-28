public import CMUXMobileCore

/// The privacy-safe reason an admitted host connection supervisor stopped.
public struct CmxIrohAdmittedConnectionExit: Equatable, Sendable {
    /// The local operation that ended the admitted connection.
    public let lifecycle: DiagnosticSessionLifecycleKind

    /// The bounded failure category, or ``DiagnosticFailureKind/none`` for an expected close.
    public let failure: DiagnosticFailureKind

    /// Creates a terminal result for one admitted host connection.
    ///
    /// - Parameters:
    ///   - lifecycle: The local operation that ended the connection.
    ///   - failure: The bounded failure category, or ``DiagnosticFailureKind/none``.
    public init(
        lifecycle: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) {
        self.lifecycle = lifecycle
        self.failure = failure
    }
}
