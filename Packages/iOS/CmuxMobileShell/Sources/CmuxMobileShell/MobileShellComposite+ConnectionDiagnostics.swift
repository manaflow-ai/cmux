public import CMUXMobileCore
public import CmuxMobileRPC

@MainActor
extension MobileShellComposite {
    /// Builds a nonblocking observer for the underlying byte-transport dial.
    /// The closure captures only the structured ring, and receives no raw route
    /// or error values from the RPC layer.
    func transportConnectDiagnosticObserver(
        peerID: String?
    ) -> (@Sendable (MobileRPCTransportConnectEvent) -> Void)? {
        guard let diagnosticLog else { return nil }
        let peerAlias = DiagnosticCorrelation().handle(for: peerID)
        return { event in
            switch event {
            case let .attempt(attemptID, transport):
                diagnosticLog.record(DiagnosticEvent(
                    .transportDialStarted,
                    surface: peerAlias,
                    a: transport.rawValue,
                    c: attemptID
                ))
            case let .connected(attemptID, transport, elapsedMilliseconds, sessionID):
                diagnosticLog.record(DiagnosticEvent(
                    .transportDialConnected,
                    surface: peerAlias,
                    ms: UInt32(clamping: elapsedMilliseconds),
                    a: transport.rawValue,
                    c: attemptID
                ))
                if let sessionID {
                    diagnosticLog.record(DiagnosticEvent(
                        .transportDialSessionLinked,
                        surface: peerAlias,
                        a: attemptID,
                        c: sessionID
                    ))
                }
            case let .failed(attemptID, transport, failure, elapsedMilliseconds):
                diagnosticLog.record(DiagnosticEvent(
                    .transportDialFailed,
                    surface: peerAlias,
                    ms: UInt32(clamping: elapsedMilliseconds),
                    a: transport.rawValue,
                    b: failure.rawValue,
                    c: attemptID
                ))
            case let .cancelled(attemptID, transport, reason, elapsedMilliseconds):
                diagnosticLog.record(DiagnosticEvent(
                    .transportDialCancelled,
                    surface: peerAlias,
                    ms: UInt32(clamping: elapsedMilliseconds),
                    a: reason.rawValue,
                    c: attemptID
                ))
            }
        }
    }

    static func diagnosticFailureKind(
        for error: (any Error)?
    ) -> DiagnosticFailureKind {
        guard let error else { return .connectionClosed }
        return DiagnosticFailureKind.classify(error)
    }

    func recordHostAuthenticationFailure(
        route: CmxAttachRoute,
        failure: DiagnosticFailureKind
    ) {
        diagnosticLog?.record(DiagnosticEvent(
            .hostAuthenticationFailed,
            a: DiagnosticTransportKind(route.kind).rawValue,
            b: failure.rawValue
        ))
    }
}
