public import CMUXMobileCore
public import IrohLib

// These conformances are deliberately categorical. They prevent callers from
// exporting `String(describing: error)`, which may contain endpoint identities,
// relay URLs, credentials, or private network addresses.

extension IrohError: @retroactive DiagnosticFailureProviding {
    public var diagnosticFailureKind: DiagnosticFailureKind {
        Self.diagnosticFailureKind(message: message())
    }

    /// iroh-ffi 1.0.2-cmux.4 (iroh 1.0.2) exposes one opaque `IrohError`
    /// object. Its `message()` retains `ReadError` case names and other errors'
    /// stable display chains, but no structured discriminator. These pinned
    /// tokens are the narrowest fallback until the binding exports a taxonomy.
    private static func diagnosticFailureKind(
        message: String
    ) -> DiagnosticFailureKind {
        if message.contains("ConnectionLost(TimedOut)") {
            return .transportIdleTimedOut
        }
        if message.contains("ConnectionLost(LocallyClosed)") {
            return .cancelled
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
        // Connection-level operations (`accept_bi`, `open_bi`, `accept_uni`,
        // `open_uni`) surface `iroh::endpoint::ConnectionError` Debug-formatted
        // WITHOUT the `ConnectionLost(...)` wrapper that stream read/write
        // errors carry (noq `ConnectionError` at manaflow-ai/noq@2271bbc, via
        // iroh-ffi 1.0.2-cmux.4). Host rings from the 2026-07-23 WiFi
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
