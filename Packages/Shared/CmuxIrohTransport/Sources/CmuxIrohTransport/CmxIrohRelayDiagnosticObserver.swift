import Foundation
public import IrohLib
import OSLog

private let relayLogger = Logger(subsystem: "com.cmux", category: "RelayTLS")

/// Observes native relay failures without probing or retaining raw error text.
///
/// The native endpoint is the source of truth for both validation and failure
/// classification. This observer owns only the latest diagnostic snapshot.
public actor CmxIrohRelayDiagnosticObserver: RelayConnectionDiagnosticCallback {
    private var previous: [RelayConnectionDiagnostic] = []
    private var failures: [RelayConnectionDiagnostic] = []

    /// Creates an observer for one endpoint generation.
    ///
    public init() {}

    /// Updates diagnostics when the native home-relay state changes.
    ///
    /// - Parameter diagnostics: Native snapshots containing no URL credentials.
    public func onChange(diagnostics snapshot: [RelayConnectionDiagnostic]) async throws {
        guard snapshot != previous else { return }
        previous = snapshot
        failures = snapshot.filter { !$0.connected && $0.failure != nil }
        for failure in failures {
            guard let kind = failure.failure else { continue }
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

    /// The last native failure, suitable for a local connection error.
    ///
    /// Includes only the failing host, port and a fixed diagnostic code. It
    /// never includes URL userinfo, paths, query strings, tokens or peer text.
    public var failureDescription: String? {
        guard let failure = failures.first, let kind = failure.failure else { return nil }
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
