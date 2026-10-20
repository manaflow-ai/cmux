public import CMUXMobileCore

extension CmxNetworkByteTransportError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .connectionTimedOut:
            .timedOut
        case let .connectionFailed(_, kind):
            kind.diagnosticFailureKind
        case .tailscaleAuthorizationUnavailable, .authorizationIntentRequired,
             .unsupportedAuthorizationMode:
            .authorizationFailed
        case .unsupportedRouteKind, .unsupportedEndpoint:
            .unsupportedRoute
        case .notConnected, .alreadyClosed, .receiveFailed, .sendFailed:
            .connectionClosed
        case .emptyHost, .invalidPort, .invalidMaximumReceiveLength,
             .receiveAlreadyInProgress, .sendAlreadyInProgress:
            .protocolViolation
        }
    }
}

private extension CmxConnectFailureKind {
    var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .connectionRefused: .connectionRefused
        case .hostUnreachable: .hostUnreachable
        case .timedOut: .timedOut
        case .permissionDenied: .permissionDenied
        case .dnsFailed: .dnsFailed
        case .secureChannelFailed: .secureChannelFailed
        case .generic: .unknown
        }
    }
}
