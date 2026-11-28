public import CMUXMobileCore

/// A privacy-safe lifecycle event for one underlying mobile transport dial.
///
/// Events contain only a local correlation number, a coarse transport class,
/// elapsed time, and a stable failure category. They never expose the route,
/// endpoint identity, relay URL, token, or raw error text.
public enum MobileRPCTransportConnectEvent: Equatable, Sendable {
    /// The transport factory is about to build and dial its route.
    case attempt(
        attemptID: Int,
        transport: DiagnosticTransportKind
    )
    /// The underlying byte transport connected successfully.
    case connected(
        attemptID: Int,
        transport: DiagnosticTransportKind,
        elapsedMilliseconds: Int,
        sessionID: Int?
    )
    /// The transport factory or underlying byte transport failed.
    case failed(
        attemptID: Int,
        transport: DiagnosticTransportKind,
        failure: DiagnosticFailureKind,
        elapsedMilliseconds: Int
    )
    /// A pending dial was cancelled by a lifecycle owner. The eventual
    /// `.failed(.cancelled)` event remains for transport outcome compatibility;
    /// this event explains who requested the cancellation.
    case cancelled(
        attemptID: Int,
        transport: DiagnosticTransportKind,
        reason: DiagnosticCancellationReason,
        elapsedMilliseconds: Int
    )
}
