import os
import CmuxSocketObservability

/// Writes slow CLI socket command observations to unified logging.
nonisolated final class UnifiedLogSlowSocketCommandSink: SlowSocketCommandSink {
    static let subsystem = "com.cmuxterm.app"
    static let category = "socket-command"

    private let logger = Logger(subsystem: subsystem, category: category)

    func recordSlowCommand(_ observation: SocketCommandObservation) {
        logger.log(
            level: .default,
            "slow socket command method=\(observation.method, privacy: .public) proto=\(observation.protocolName, privacy: .public) ms=\(observation.durationMs, format: .fixed(precision: 1), privacy: .public) onMain=\(observation.executedOnMain, privacy: .public) peerPid=\(observation.peerPid.map(Int.init) ?? -1, privacy: .public) bytes=\(observation.responseByteCount, privacy: .public)"
        )
        sentryBreadcrumb(
            "socket.command.slow",
            category: "socket",
            data: [
                "method": observation.method,
                "protocol": observation.protocolName,
                "durationMs": observation.durationMs,
                "executedOnMain": observation.executedOnMain,
                "peerPid": observation.peerPid.map(Int.init) ?? -1,
                "responseByteCount": observation.responseByteCount
            ]
        )
    }
}
