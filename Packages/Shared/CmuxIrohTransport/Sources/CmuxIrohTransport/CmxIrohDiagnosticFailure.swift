public import CMUXMobileCore
public import IrohLib

// These conformances are deliberately categorical. They prevent callers from
// exporting `String(describing: error)`, which may contain endpoint identities,
// relay URLs, credentials, or private network addresses.

/// Recognizes operating-system route failures that Iroh currently exposes only
/// through an opaque display string. Keep this list narrow. A peer-controlled
/// close reason must not be allowed to turn an established-session close into a
/// local route diagnosis.
enum CmxIrohRouteFailureClassifier {
    static func classify(_ message: String) -> DiagnosticFailureKind? {
        let normalized = message.lowercased()
        // These strings describe an already established close, or contain
        // peer-controlled application text. They are not local route
        // evidence, even when the peer's reason happens to say "no route".
        if normalized.hasPrefix("closed by peer:")
            || normalized.hasPrefix("aborted by peer:")
            || normalized.hasPrefix("reset by peer:")
            || normalized.contains("connectionlost(")
            || normalized.contains("applicationclosed(")
            || normalized.contains("connectionclosed(") {
            return nil
        }
        if normalized.contains("connection refused")
            || normalized.contains("econnrefused") {
            return .connectionRefused
        }
        if normalized.contains("network is unreachable")
            || normalized.contains("no route to host")
            || normalized.contains("host unreachable")
            || normalized.contains("enetunreach")
            || normalized.contains("ehostunreach") {
            return .hostUnreachable
        }
        if normalized.contains("no route")
            || normalized.contains("no usable route")
            || normalized.contains("no usable path")
            || normalized.contains("no route candidates") {
            return .noRoute
        }
        return nil
    }
}

extension IrohError: @retroactive DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        Self.diagnosticFailureKind(message: message())
    }

    /// iroh-ffi 1.0.2-cmux.4 and later (iroh 1.0.2) expose one opaque `IrohError`
    /// object. Its `message()` retains `ReadError` case names and other errors'
    /// stable display chains, but no structured discriminator. These pinned
    /// tokens are the narrowest fallback until the binding exports a taxonomy.
    private static func diagnosticFailureKind(
        message: String
    ) -> DiagnosticFailureKind {
        // iroh-ffi's ConnectAttempt fails a cancelled dial with this fixed marker
        // (CONNECT_CANCELLED_MESSAGE, iroh-ffi src/endpoint.rs, v1.0.2-cmux.4+).
        if message.contains("outgoing connection cancelled") {
            return .cancelled
        }
        if message.contains("ConnectionLost(TimedOut)") {
            return .transportIdleTimedOut
        }
        if message.contains("ConnectionLost(LocallyClosed)") {
            return .cancelled
        }
        // ConnectAttempt can render a peer close without the structured
        // ConnectionLost wrapper. Preserve the same attribution rule here:
        // the peer's reason is not local route evidence.
        let normalized = message.lowercased()
        if normalized.hasPrefix("closed by peer:")
            || normalized.hasPrefix("aborted by peer:")
            || normalized.hasPrefix("reset by peer:") {
            return .connectionClosed
        }
        if message.contains("TransportError(")
            && (message.contains("Code::crypto(")
                || message.contains("TLS error:")) {
            return .secureChannelFailed
        }
        if message.contains("ConnectionLost(Reset)")
            || message.contains("ConnectionLost(TransportError(")
            || message.contains("ConnectionLost(ApplicationClosed(")
            || message.contains("ConnectionLost(ConnectionClosed(") {
            return .connectionClosed
        }
        if message.contains("AddressLookupFailed")
            || message.contains("DnsLookup")
            || message.contains("DNS lookup")
            || message.contains("No addressing information available")
            || message.contains("No address lookup configured")
            || message.contains("All address lookup services failed or produced no results")
            || message.contains("Failed to resolve TXT record")
            || message.contains("Resolve failed, IPv4:")
            || message.contains("Failed to resolve") {
            return .dnsFailed
        }
        // Route words are meaningful only on an opaque pre-connection error.
        // Structured close markers above describe an already admitted session;
        // a peer-controlled application reason must never be exported as a
        // local no-route diagnosis.
        if let routeFailure = CmxIrohRouteFailureClassifier.classify(message) {
            return routeFailure
        }
        // Connection-level operations (`accept_bi`, `open_bi`, `accept_uni`,
        // `open_uni`) surface `iroh::endpoint::ConnectionError` Debug-formatted
        // WITHOUT the `ConnectionLost(...)` wrapper that stream read/write
        // errors carry (noq `ConnectionError` at manaflow-ai/noq@2271bbc, via
        // iroh-ffi 1.0.2-cmux.4+). Host rings from the 2026-07-23 WiFi
        // path-flap loop showed admitted sessions dying `applicationLaneFailed`
        // with these bare tokens classified `unknown`.
        if message.contains("TimedOut") {
            return .transportIdleTimedOut
        }
        if message.contains("LocallyClosed") {
            return .cancelled
        }
        if message.contains("VersionMismatch") {
            return .protocolViolation
        }
        if message.contains("CidsExhausted") {
            return .endpointUnavailable
        }
        if message.contains("ApplicationClosed(")
            || message.contains("ConnectionClosed(")
            || message.contains("TransportError(")
            || message.contains("Reset") {
            return .connectionClosed
        }
        if message.contains("timed out")
            || message.contains("Timed out")
            || message.contains("Timeout") {
            return .timedOut
        }
        if message.contains("Tls")
            || message.contains("TLS")
            || message.contains("CryptoError")
            || message.contains("Code::crypto(")
            || message.contains("Certificate")
            || message.contains("certificate")
            || message.contains("Handshake")
            || message.contains("handshake")
            || message.contains("crypto provider") {
            return .secureChannelFailed
        }
        if message.contains("ConnectionLost(")
            || message.contains("ClosedStream")
            || message.contains("Reset(")
            || message.contains("Stopped(") {
            return .connectionClosed
        }
        return .unknown
    }
}

extension CmxIrohTrustBrokerClientError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .connectivity:
            .offline
        case .missingAuthentication, .invalidAuthentication:
            .authorizationFailed
        case .rateLimited:
            .policyUnavailable
        case let .rejected(statusCode, _):
            switch statusCode {
            case 401, 403: .authorizationFailed
            case 408: .timedOut
            default: .policyUnavailable
            }
        case .invalidBaseURL, .nonHTTPResponse, .invalidResponse:
            .protocolViolation
        }
    }
}

extension CmxIrohByteTransportError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .unsupportedRouteKind, .unsupportedEndpoint:
            .unsupportedRoute
        case .missingPeerIntent:
            .authorizationFailed
        case .alreadyClosed, .notConnected, .controlLaneAlreadyOwned:
            .connectionClosed
        }
    }
}

extension CmxIrohClientRuntimeError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .inactive, .alreadyActive:
            .endpointUnavailable
        case .invalidLocalBinding, .localBindingMissingFromDiscovery:
            .identityMismatch
        case .relayFleetMismatch:
            .policyUnavailable
        case .routeContractMismatch:
            .protocolViolation
        case .superseded:
            .superseded
        }
    }
}

extension CmxIrohHostRuntimeError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .inactive, .alreadyActive:
            .endpointUnavailable
        case .invalidLocalBinding, .localBindingMissingFromDiscovery:
            .identityMismatch
        case .relayFleetMismatch:
            .policyUnavailable
        case .routeContractMismatch:
            .protocolViolation
        case .superseded:
            .superseded
        }
    }
}

extension CmxIrohClientSessionError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .remoteIdentityMismatch:
            .identityMismatch
        case .admissionDenied:
            .admissionDenied
        case .dialTimedOut:
            .timedOut
        case .alreadyClosed, .notConnected, .unexpectedEndOfStream:
            .connectionClosed
        case .invalidAdmissionFrame, .invalidMaximumByteCount,
             .invalidOutgoingLane, .applicationLanesUnavailable:
            .protocolViolation
        }
    }
}

extension CmxIrohServerSessionError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .admissionDenied:
            .admissionDenied
        case .alreadyClosed, .notAdmitted, .unexpectedEndOfStream:
            .connectionClosed
        case .streamHeaderTimedOut:
            .timedOut
        case .alreadyAdmitted, .invalidAdmissionFrame, .invalidFirstLane,
             .invalidPeerLane, .invalidServerLane, .applicationLanesUnavailable,
             .applicationLaneRejected:
            .protocolViolation
        }
    }
}

extension CmxIrohLibError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .invalidEndpointIdentity, .remoteIdentityMismatch:
            .identityMismatch
        case .expiredRelayCredential:
            .credentialUnavailable
        case .unmanagedRelayURL, .unsupportedRelayIdentifier:
            .policyUnavailable
        case .unexpectedALPN, .invalidReceiveLimit:
            .protocolViolation
        }
    }
}

extension CmxIrohEndpointSupervisorError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .inactive: .endpointUnavailable
        case .relayReadinessTimedOut: .endpointUnavailable
        case .superseded: .superseded
        }
    }
}

extension CmxIrohRelayPolicyServiceError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .brokerUnavailable: .policyUnavailable
        case .managedCredentialUnavailable: .credentialUnavailable
        case .preferenceRollback: .policyUnavailable
        case .superseded: .superseded
        }
    }
}

extension CmxIrohRelayCredentialCoordinatorError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .inactive: .endpointUnavailable
        case .relayFleetMismatch: .policyUnavailable
        }
    }
}

extension CmxIrohRegistryContextError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .unsupportedRoute, .dialPlanUnavailable:
            .noRoute
        case .incompatibleContract:
            .protocolViolation
        case .relayFleetMismatch, .invalidGrantExpiry:
            .policyUnavailable
        case .localBindingUnavailable, .targetBindingUnavailable:
            .endpointUnavailable
        case .targetDeviceMismatch:
            .identityMismatch
        case .targetNotPairable:
            .authorizationFailed
        }
    }
}

extension CmxIrohGrantVerifierError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .identityMismatch:
            .identityMismatch
        case .accountMismatch:
            .accountMismatch
        case .expired:
            .authorizationFailed
        case .invalidKeySet, .invalidToken, .invalidHeader, .unknownKeyID,
             .invalidSignature, .invalidClaims:
            .protocolViolation
        }
    }
}

extension CmxIrohPrivateFallbackValidationError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .unavailable, .profileUnavailable, .hintExpiredOrInvalid:
            .noRoute
        case .authorizationMismatch, .generationChanged:
            .authorizationFailed
        }
    }
}

extension CmxIrohKeychainCredentialStoreError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind { .credentialUnavailable }
}

extension CmxIrohKeychainIdentityStoreError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind { .credentialUnavailable }
}

extension CmxIrohClientOfflinePolicyCacheError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .invalidExpectation, .invalidPolicy, .policyMismatch:
            .policyUnavailable
        case .invalidGrantEnvelope:
            .protocolViolation
        }
    }
}

extension CmxIrohHostPolicyCacheError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .invalidExpectation, .invalidPolicy, .policyMismatch:
            .policyUnavailable
        case .invalidAttestationEnvelope:
            .protocolViolation
        }
    }
}

extension CmxIrohLocalBindingExpectationError: DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind { .protocolViolation }
}
