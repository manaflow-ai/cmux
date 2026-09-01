import Foundation

public extension CmxTransportMode {
    /// Stable integer vocabulary used by diagnostic event payloads.
    var diagnosticMode: DiagnosticTransportMode {
        DiagnosticTransportMode(self)
    }
}
