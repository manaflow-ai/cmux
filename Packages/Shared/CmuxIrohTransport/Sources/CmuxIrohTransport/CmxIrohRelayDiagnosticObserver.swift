import Foundation
public import IrohLib
import OSLog

nonisolated private let relayLogger = Logger(subsystem: "com.cmux", category: "RelayTLS")

/// Observes native relay failures without probing or retaining raw error text.
///
/// The native endpoint owns diagnostic state and deduplicates notifications.
/// This stateless bridge only logs; readiness reads the endpoint directly.
public final class CmxIrohRelayDiagnosticObserver: RelayConnectionDiagnosticCallback {
    /// Creates a stateless native logging callback.
    ///
    public init() {}

    /// Logs failures when native certificate or relay state changes.
    ///
    /// - Parameter diagnostics: Native snapshots containing no URL credentials.
    public func onChange(diagnostics snapshot: [RelayConnectionDiagnostic]) async throws {
        for failure in snapshot {
            guard !failure.connected, let kind = failure.failure else { continue }
            let code = Self.code(kind)
            let port = failure.port.map(String.init) ?? "unknown"
            #if os(macOS)
            let trust = "system"
            #else
            let trust = "embedded"
            #endif
            relayLogger.error("relay.connection.failed host=\(failure.host, privacy: .public) port=\(port, privacy: .public) cause=\(code, privacy: .public) trust=\(trust, privacy: .public)")
        }
    }

    /// Formats a current native snapshot for a local connection error.
    ///
    /// Includes only the failing host, port and a fixed diagnostic code. It
    /// never includes URL userinfo, paths, query strings, tokens or peer text.
    /// - Parameter diagnostics: Read directly from the active native endpoint.
    /// - Returns: The first failure, or nil when the snapshot has no failure.
    public static func failureDescription(for diagnostics: [RelayConnectionDiagnostic]) -> String? {
        guard let failure = diagnostics.first(where: { !$0.connected && $0.failure != nil }),
              let kind = failure.failure else { return nil }
        return String(
            format: String(
                localized: "connection.relay.nativeFailure",
                defaultValue: "Relay connection to %1$@ failed: %2$@."
            ),
            failure.port.map { "\(failure.host):\($0)" } ?? failure.host,
            Self.code(kind)
        )
    }

    private static func code(_ kind: RelayFailureKind) -> String {
        switch kind {
        case .unknownIssuer: "UnknownIssuer"
        case .hostnameMismatch: "HostnameMismatch"
        case .certificateExpired: "CertificateExpired"
        case .certificateNotYetValid: "CertificateNotYetValid"
        case .certificateRevoked: "CertificateRevoked"
        case .systemTrustFailed: "SystemTrustFailed"
        case .tlsFailed: "TLSFailed"
        case .networkFailed: "NetworkFailed"
        case .other: "Other"
        }
    }
}
