public import CMUXMobileCore

/// Records classified connection-boundary events with one session correlation ID.
public struct CmxIrohConnectionDiagnosticRecorder: Sendable {
    private let diagnosticLog: DiagnosticLog
    private let sessionID: Int
    private let peerAlias: UInt32?

    /// Creates a recorder for one process-local session.
    ///
    /// - Parameters:
    ///   - diagnosticLog: The bounded destination diagnostic ring.
    ///   - sessionID: The positive ID shared with session lifecycle events.
    public init(
        diagnosticLog: DiagnosticLog,
        sessionID: Int,
        peerAlias: UInt32? = nil
    ) {
        precondition(sessionID > 0)
        self.diagnosticLog = diagnosticLog
        self.sessionID = sessionID
        self.peerAlias = peerAlias
    }

    /// Records one classified terminal connection cause.
    ///
    /// - Parameter attribution: The privacy-safe close attribution.
    public func record(
        _ attribution: CmxIrohConnectionCloseAttribution
    ) {
        diagnosticLog.record(DiagnosticEvent(
            .transportCloseAttribution,
            surface: peerAlias,
            ms: Self.diagnosticApplicationErrorCode(
                attribution.applicationErrorCode
            ),
            a: attribution.initiator.rawValue,
            b: attribution.failureKind.rawValue,
            c: sessionID
        ))
        diagnosticLog.record(DiagnosticEvent(
            .transportCloseReason,
            surface: peerAlias,
            a: attribution.remoteReason.rawValue,
            c: sessionID
        ))
    }

    /// Records one redacted path lifecycle event.
    ///
    /// - Parameter event: The bounded path operation and path category.
    public func record(_ event: CmxIrohConnectionPathEvent) {
        diagnosticLog.record(DiagnosticEvent(
            .transportPathEvent,
            surface: peerAlias,
            a: event.kind.rawValue,
            b: event.pathKind.rawValue,
            c: sessionID
        ))
    }

    private static func diagnosticApplicationErrorCode(
        _ code: Int64?
    ) -> UInt32? {
        guard let code else { return nil }
        return UInt32(max(0, min(code, Int64(Int32.max))))
    }
}
