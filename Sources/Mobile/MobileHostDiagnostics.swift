import CMUXMobileCore
import Foundation
import OSLog

/// App-owned diagnostics shared by mobile transports, stream producers and exports.
final class MobileHostDiagnostics {
    /// Remains readable off the main actor when a stalled UI needs diagnostics.
    nonisolated static let log = DiagnosticLog(
        buildStamp: DiagnosticBuildStamp.make(infoDictionary: Bundle.main.infoDictionary),
        role: .macHost
    )

    nonisolated static let logger = Logger(
        subsystem: "dev.cmux",
        category: "mobile-host"
    )

    private init() {}
}
