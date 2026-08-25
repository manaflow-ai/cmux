import Foundation
import OSLog

nonisolated private let agentHookDeliveryLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "AgentHookDelivery"
)

extension CMUXCLI {
    /// Chooses a currently verified hook PID, retaining a mapped fallback when verification fails.
    func preferredAgentHookEventPID(
        agentName: String,
        mappedPID: Int?,
        inferredPID: Int?
    ) -> Int? {
        if agentName == "codex" {
            return inferredPID ?? mappedPID
        }
        guard let inferredPID else {
            return mappedPID
        }
        // A generic provider can restart between hooks, leaving the durable
        // session record pointed at its old PID until SessionStart runs. Use
        // the current hook PID when its exact generation is readable; an
        // unverified ambient claim must not displace the mapped owner.
        guard AgentPIDProcessIdentity(agentTurnPID: inferredPID) != nil else {
            return mappedPID ?? inferredPID
        }
        return inferredPID
    }

    /// Reports a persistently throttled hook failure without serializing raw transport details.
    func reportAgentHookFailure(
        stage: AgentHookFailureStage,
        agentName: String,
        sessionId: String,
        event: String,
        error: Error? = nil,
        store: ClaudeHookSessionStore,
        telemetry: CLISocketSentryTelemetry,
        deadline: Date? = nil
    ) {
        let shortSessionId = String(sessionId.prefix(12))
        let errorType = error.map { String(reflecting: type(of: $0)) } ?? "unresolved-target"
        let failureDescription: String
        switch stage {
        case .targetResolution:
            failureDescription = String.localizedStringWithFormat(
                String(
                    localized: "cli.agentHook.error.targetResolution",
                    defaultValue: "Agent hook target resolution failed for %@ %@."
                ),
                agentName,
                event
            )
        case .notificationDelivery:
            failureDescription = String.localizedStringWithFormat(
                String(
                    localized: "cli.agentHook.error.notificationDelivery",
                    defaultValue: "Agent hook notification delivery failed for %@ %@."
                ),
                agentName,
                event
            )
        case .journalAppend:
            failureDescription = String.localizedStringWithFormat(
                String(
                    localized: "cli.agentHook.error.journalAppend",
                    defaultValue: "Agent hook journal append failed for %@ %@."
                ),
                agentName,
                event
            )
        }
        let userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: failureDescription,
            NSDebugDescriptionErrorKey: failureDescription,
            "underlying_error_type": errorType,
        ]
        let reportableError = NSError(
            domain: "com.cmuxterm.cli.agent-hook.\(stage.rawValue)",
            code: 1,
            userInfo: userInfo
        )
        let telemetryStage = "agent-hook-\(stage.rawValue)"
        let telemetryData: [String: Any] = [
            "agent": agentName,
            "hook_event": event,
            "has_session_id": !sessionId.isEmpty,
            "underlying_error_type": errorType,
            "failure_description": failureDescription,
        ]
        // Classify before claiming the durable slot. Expected lifecycle noise
        // must not suppress a later actionable failure for the same session.
        guard !telemetry.isExpectedFailure(
            stage: telemetryStage,
            error: reportableError,
            data: telemetryData,
            classificationError: error
        ) else {
            return
        }
        guard (try? store.claimAgentHookFailureReport(
            agentName: agentName,
            stage: stage.rawValue,
            sessionId: sessionId,
            deadline: deadline
        )) == true else {
            return
        }
        agentHookDeliveryLogger.error(
            "Agent hook failed stage=\(stage.rawValue, privacy: .public) event=\(event, privacy: .public) agent=\(agentName, privacy: .public) session=\(shortSessionId, privacy: .private(mask: .hash)) errorType=\(errorType, privacy: .private(mask: .hash)) description=\(failureDescription, privacy: .public)"
        )
        telemetry.captureError(
            stage: telemetryStage,
            error: reportableError,
            data: telemetryData,
            classificationError: error
        )
    }
}
