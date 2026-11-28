import Foundation
public import IrohLib

extension RelayConnectionDiagnostic {
    /// A local error message containing only the native host, port and cause.
    ///
    /// Read the snapshot from the active endpoint at the failure boundary.
    /// Connected relays and snapshots without failures have no description.
    public var failureDescription: String? {
        guard !connected, let failure else { return nil }
        return String(
            format: String(
                localized: "connection.relay.nativeFailure",
                defaultValue: "Relay connection to %1$@ failed: %2$@."
            ),
            port.map { "\(host):\($0)" } ?? host,
            failure.diagnosticCode
        )
    }
}
