#if canImport(IrohLib)
public import CMUXMobileCore
public import IrohLib

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
#endif
