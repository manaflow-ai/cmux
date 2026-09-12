import Foundation
import os
import CmuxSocketObservability

/// Writes main-thread socket command watchdog events to unified logging.
nonisolated final class UnifiedLogMainThreadSocketCommandWatchdogReporter: MainThreadSocketCommandWatchdogReporter {
    private static let subsystem = "com.cmuxterm.app"
    private static let category = "socket-command-watchdog"

    private let logger = Logger(
        subsystem: UnifiedLogMainThreadSocketCommandWatchdogReporter.subsystem,
        category: UnifiedLogMainThreadSocketCommandWatchdogReporter.category
    )

    func reportHang(_ observation: MainThreadSocketCommandWatchdogObservation) {
        let descriptor = observation.descriptor
        logger.error(
            "main-thread socket command exceeded watchdog method=\(descriptor.method, privacy: .public) proto=\(descriptor.protocolName, privacy: .public) ms=\(observation.elapsedMs, format: .fixed(precision: 0), privacy: .public) thresholdMs=\(observation.thresholdMs, format: .fixed(precision: 0), privacy: .public) peerPid=\(descriptor.peerPid.map(Int.init) ?? -1, privacy: .public) backtrace=\(Self.backtraceSummary(observation.backtrace), privacy: .public)"
        )
        sentryBreadcrumb(
            "socket.command.main_thread_watchdog",
            category: "socket",
            data: [
                "method": descriptor.method,
                "protocol": descriptor.protocolName,
                "elapsedMs": observation.elapsedMs,
                "thresholdMs": observation.thresholdMs,
                "peerPid": descriptor.peerPid.map(Int.init) ?? -1
            ]
        )
    }

    func reportRecovery(_ observation: MainThreadSocketCommandWatchdogObservation) {
        let descriptor = observation.descriptor
        logger.log(
            level: .default,
            "main-thread socket command completed after watchdog method=\(descriptor.method, privacy: .public) proto=\(descriptor.protocolName, privacy: .public) ms=\(observation.elapsedMs, format: .fixed(precision: 0), privacy: .public) thresholdMs=\(observation.thresholdMs, format: .fixed(precision: 0), privacy: .public) peerPid=\(descriptor.peerPid.map(Int.init) ?? -1, privacy: .public)"
        )
    }

    private static func backtraceSummary(_ backtrace: [String]) -> String {
        "best-effort live sample: " + String(backtrace.prefix(32).joined(separator: " | ").prefix(4096))
    }
}
