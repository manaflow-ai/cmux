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

    /// Creates a classified connection-close attribution.
    ///
    /// - Parameters:
    ///   - initiator: Which endpoint or condition initiated the close.
    ///   - applicationErrorCode: The optional QUIC application error code.
    ///   - failureKind: The bounded diagnostic failure category.
    public init(
        initiator: CmxIrohConnectionCloseInitiator,
        applicationErrorCode: Int64?,
        failureKind: DiagnosticFailureKind
    ) {
        self.initiator = initiator
        self.applicationErrorCode = applicationErrorCode
        self.failureKind = failureKind
    }

    /// Classifies an opaque iroh-ffi close cause without retaining its text.
    ///
    /// iroh-ffi 1.0.2-cmux.4 exposes the terminal cause as a string. These
    /// tokens mirror the package's pinned `IrohError` classification until the
    /// binding exports a structured close-reason taxonomy.
    ///
    /// - Parameter cause: The ephemeral close-cause string from IrohLib.
    /// - Returns: A bounded attribution containing no raw cause text.
    public static func classify(_ cause: String) -> Self {
        Self(
            initiator: initiator(in: cause),
            applicationErrorCode: applicationErrorCode(in: cause),
            failureKind: failureKind(in: cause)
        )
    }

    private static func initiator(
        in cause: String
    ) -> CmxIrohConnectionCloseInitiator {
        let normalized = cause.lowercased()
        if normalized.contains("peer") || normalized.contains("remote") {
            return .remote
        }
        if normalized.contains("local") {
            return .local
        }
        if normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("timedout") {
            return .timedOut
        }
        return .unknown
    }

    private static func applicationErrorCode(in cause: String) -> Int64? {
        for label in ["application error code", "application_error_code", "error code", "error_code", "code"] {
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
        return lastInteger(in: cause[...])
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

    private static func lastInteger(
        in text: Substring
    ) -> Int64? {
        var last: Int64?
        var token = ""
        for character in text {
            if character.isNumber || (character == "-" && token.isEmpty) {
                token.append(character)
            } else if !token.isEmpty {
                if token != "-", let value = Int64(token) {
                    last = value
                }
                token.removeAll(keepingCapacity: true)
            }
        }
        if token != "-", let value = Int64(token) {
            last = value
        }
        return last
    }

    private static func failureKind(in cause: String) -> DiagnosticFailureKind {
        if cause.contains("ConnectionLost(TimedOut)") {
            return .transportIdleTimedOut
        }
        if cause.contains("ConnectionLost(LocallyClosed)") {
            return .cancelled
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
        if cause.localizedCaseInsensitiveContains("timed out")
            || cause.localizedCaseInsensitiveContains("timeout") {
            return .timedOut
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
            || cause.contains("Stopped(")
            || cause.localizedCaseInsensitiveContains("closed") {
            return .connectionClosed
        }
        return .unknown
    }
}
