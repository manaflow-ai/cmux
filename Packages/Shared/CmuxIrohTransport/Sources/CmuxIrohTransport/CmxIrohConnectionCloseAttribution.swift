public import CMUXMobileCore
import Foundation

/// A privacy-safe classification of one terminal Iroh connection cause.
///
/// This value retains only bounded enums and an optional numeric QUIC
/// application error code. The raw FFI cause string is consumed only by
/// ``classify(_:)`` and is never stored.
public struct CmxIrohConnectionCloseAttribution: Sendable, Equatable {
    /// Which endpoint or transport condition initiated the close.
    public let initiator: CmxIrohConnectionCloseInitiator
    /// The QUIC application error code when the cause exposed one.
    public let applicationErrorCode: Int64?
    /// The bounded failure category derived from the cause.
    public let failureKind: DiagnosticFailureKind
    /// A whitelisted peer close token, when the protocol supplied one.
    public let remoteReason: DiagnosticRemoteCloseReason

    /// Creates a classified connection-close attribution.
    ///
    /// - Parameters:
    ///   - initiator: Which endpoint or condition initiated the close.
    ///   - applicationErrorCode: The optional QUIC application error code.
    ///   - failureKind: The bounded diagnostic failure category.
    public init(
        initiator: CmxIrohConnectionCloseInitiator,
        applicationErrorCode: Int64?,
        failureKind: DiagnosticFailureKind,
        remoteReason: DiagnosticRemoteCloseReason = .unknown
    ) {
        self.initiator = initiator
        self.applicationErrorCode = applicationErrorCode
        self.failureKind = failureKind
        self.remoteReason = remoteReason
    }

    /// Classifies an opaque iroh-ffi close cause without retaining its text.
    ///
    /// iroh-ffi 1.0.2-cmux.4 and later expose the terminal cause as a string. These
    /// tokens mirror the package's pinned `IrohError` classification until the
    /// binding exports a structured close-reason taxonomy.
    ///
    /// - Parameter cause: The ephemeral close-cause string from IrohLib.
    /// - Returns: A bounded attribution containing no raw cause text.
    public static func classify(_ cause: String) -> Self {
        let remoteReason = remoteReason(in: cause)
        return Self(
            initiator: initiator(in: cause),
            applicationErrorCode: applicationErrorCode(in: cause),
            failureKind: failureKind(in: cause, remoteReason: remoteReason),
            remoteReason: remoteReason
        )
    }

    private static func initiator(
        in cause: String
    ) -> CmxIrohConnectionCloseInitiator {
        if cause.contains("ConnectionLost(LocallyClosed)") {
            return .local
        }
        if cause.contains("ConnectionLost(TimedOut)") {
            return .timedOut
        }
        if cause.contains("ConnectionLost(ApplicationClosed(")
            || cause.contains("ConnectionLost(ConnectionClosed(")
            || cause.contains("ConnectionLost(Reset)") {
            return .remote
        }
        // Connection.closed()/close_reason() cross the uniffi boundary as
        // quinn ConnectionError DISPLAY strings, which start with the variant
        // text. Prefix-anchoring keeps a peer-chosen close reason from
        // spoofing a different initiator.
        if cause.hasPrefix("closed by peer")
            || cause.hasPrefix("aborted by peer")
            || cause.hasPrefix("reset by peer") {
            return .remote
        }
        if cause == "timed out" {
            return .timedOut
        }
        if cause == "closed" {
            return .local
        }
        return .unknown
    }

    private static func applicationErrorCode(in cause: String) -> Int64? {
        // Display format of a peer application close is either
        // "closed by peer: {code}" or "closed by peer: {reason} (code {code})";
        // the formatter always appends the authentic code last, so a code-like
        // fragment inside the peer-chosen reason cannot shadow it.
        let displayPeerClose = "closed by peer: "
        if cause.hasPrefix(displayPeerClose) {
            let payload = cause.dropFirst(displayPeerClose.count)
            if let range = payload.range(of: "(code ", options: .backwards) {
                return firstInteger(in: payload[range.upperBound...])
            }
            return firstInteger(in: payload)
        }
        guard cause.contains("ApplicationClosed(") else { return nil }
        for label in [
            "application error code",
            "application_error_code",
            "error code",
            "error_code",
        ] {
            guard let range = cause.range(
                of: label,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            if let value = firstInteger(in: cause[range.upperBound...]) {
                return value
            }
        }
        return nil
    }

    private static func firstInteger(
        in text: Substring
    ) -> Int64? {
        var token = ""
        for character in text {
            if character.isNumber || (character == "-" && token.isEmpty) {
                token.append(character)
            } else if !token.isEmpty {
                if token != "-", let value = Int64(token) {
                    return value
                }
                token.removeAll(keepingCapacity: true)
            }
        }
        guard token != "-" else { return nil }
        return Int64(token)
    }

    private static func failureKind(
        in cause: String,
        remoteReason: DiagnosticRemoteCloseReason
    ) -> DiagnosticFailureKind {
        switch remoteReason {
        case .clientClosed, .serverCancelled:
            return .cancelled
        case .superseded:
            return .superseded
        case .admissionLeaseExpired:
            return .admissionLeaseExpired
        case .admissionRevalidationFailed:
            return .admissionRevalidationFailed
        case .sendQueueOverflow:
            return .sendQueueOverflow
        case .serverFailure:
            return .connectionClosed
        case .serverClosed, .unknown:
            break
        }
        if cause.contains("ConnectionLost(TimedOut)") || cause == "timed out" {
            return .transportIdleTimedOut
        }
        if cause.contains("ConnectionLost(LocallyClosed)") || cause == "closed" {
            return .cancelled
        }
        // Display-format peer closes are prefix-anchored so a peer-chosen
        // reason cannot rewrite the kind via the keyword fallbacks below.
        if cause.hasPrefix("closed by peer")
            || cause.hasPrefix("aborted by peer")
            || cause.hasPrefix("reset by peer") {
            return .connectionClosed
        }
        if cause.contains("ConnectionLost(TransportError(")
            && (cause.contains("Code::crypto(")
                || cause.contains("TLS error:")) {
            return .secureChannelFailed
        }
        if cause.contains("ConnectionLost(Reset)")
            || cause.contains("ConnectionLost(TransportError(")
            || cause.contains("ConnectionLost(ApplicationClosed(")
            || cause.contains("ConnectionLost(ConnectionClosed(") {
            return .connectionClosed
        }
        if cause.contains("AddressLookupFailed")
            || cause.contains("DnsLookup")
            || cause.contains("DNS lookup")
            || cause.contains("No addressing information available")
            || cause.contains("No address lookup configured")
            || cause.contains("All address lookup services failed or produced no results")
            || cause.contains("Failed to resolve TXT record")
            || cause.contains("Resolve failed, IPv4:")
            || cause.contains("Failed to resolve") {
            return .dnsFailed
        }
        // Only classify route words after structured close and DNS markers.
        // A peer-chosen reason such as "No route found" is not evidence that
        // this device lacked a route.
        if let routeFailure = CmxIrohRouteFailureClassifier.classify(cause) {
            return routeFailure
        }
        if cause.contains("Tls")
            || cause.contains("TLS")
            || cause.contains("CryptoError")
            || cause.contains("Code::crypto(")
            || cause.contains("Certificate")
            || cause.contains("certificate")
            || cause.contains("Handshake")
            || cause.contains("handshake")
            || cause.contains("crypto provider") {
            return .secureChannelFailed
        }
        if cause.contains("ConnectionLost(")
            || cause.contains("ClosedStream")
            || cause.contains("Reset(")
            || cause.contains("Stopped(") {
            return .connectionClosed
        }
        return .unknown
    }

    /// Extracts only protocol-owned reason tokens. Free-form peer text is
    /// intentionally ignored so it cannot spoof a diagnostic category.
    private static func remoteReason(
        in cause: String
    ) -> DiagnosticRemoteCloseReason {
        let tokens: [String: DiagnosticRemoteCloseReason] = [
            "client_closed": .clientClosed,
            "server_closed": .serverClosed,
            "superseded_session": .superseded,
            "admission_lease_expired": .admissionLeaseExpired,
            "admission_revalidation_failed": .admissionRevalidationFailed,
            "send_queue_overflow": .sendQueueOverflow,
            "server_failed": .serverFailure,
            "server_cancelled": .serverCancelled,
        ]
        let displayToken: String? = {
            for prefix in ["closed by peer: ", "aborted by peer: "] {
                guard cause.hasPrefix(prefix) else { continue }
                let remainder = cause.dropFirst(prefix.count)
                return remainder.split(
                    whereSeparator: { $0 == " " || $0 == "(" }
                ).first.map(String.init)
            }
            return nil
        }()
        for (token, reason) in tokens {
            if cause.contains("reason: \"\(token)\"")
                || cause.contains("reason: b\"\(token)\"")
                || displayToken == token {
                return reason
            }
        }
        return .unknown
    }
}
