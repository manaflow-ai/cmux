import CMUXMobileCore
import Foundation

/// Process-wide owner of the Mac host's transport diagnostics ring.
enum MobileHostDiagnostics {
    /// The host diagnostic ring, deliberately `nonisolated` so read paths can
    /// snapshot it without a main-actor hop: the ring must stay exportable
    /// even when the main thread is wedged, which is exactly when connection
    /// diagnostics matter most.
    nonisolated static let hostDiagnosticLog = DiagnosticLog(
        buildStamp: diagnosticBuildStamp,
        role: .macHost
    )

    private nonisolated static var diagnosticBuildStamp: String {
        DiagnosticBuildStamp.make(infoDictionary: Bundle.main.infoDictionary)
    }
}
