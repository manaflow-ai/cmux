import Foundation
import OSLog

private let agentHookDeliveryLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "AgentHookDelivery"
)

extension CMUXCLI {
    func preferredAgentHookEventPID(
        agentName: String,
        mappedPID: Int?,
        inferredPID: Int?
    ) -> Int? {
        agentName == "codex"
            ? inferredPID ?? mappedPID
            : mappedPID ?? inferredPID
    }

    func reportAgentHookNotificationDeliveryFailure(
        agentName: String,
        sessionId: String,
        error: Error,
        telemetry: CLISocketSentryTelemetry
    ) {
        let shortSessionId = String(sessionId.prefix(12))
        agentHookDeliveryLogger.error(
            "Notification delivery failed agent=\(agentName, privacy: .public) session=\(shortSessionId, privacy: .private(mask: .hash)) error=\(String(describing: error), privacy: .public)"
        )
        telemetry.captureError(
            stage: "agent-hook-notification-delivery",
            error: error,
            data: [
                "agent": agentName,
                "has_session_id": !sessionId.isEmpty,
            ]
        )
    }
}
