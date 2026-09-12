import Foundation

/// Exposes the stable diagnostic vocabulary for configured transport modes.
public extension CmxTransportMode {
    /// Stable integer vocabulary used by diagnostic event payloads.
    var diagnosticMode: DiagnosticTransportMode {
        DiagnosticTransportMode(self)
    }
}
