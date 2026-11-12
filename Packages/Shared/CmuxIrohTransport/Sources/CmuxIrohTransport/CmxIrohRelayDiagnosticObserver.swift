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
            let code = kind.diagnosticCode
            let port = failure.port.map(String.init) ?? "unknown"
            #if os(macOS)
            let trust = "system"
            #else
            let trust = "embedded"
            #endif
            relayLogger.error("relay.connection.failed host=\(failure.host, privacy: .public) port=\(port, privacy: .public) cause=\(code, privacy: .public) trust=\(trust, privacy: .public)")
        }
    }

}
