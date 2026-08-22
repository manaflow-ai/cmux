import Foundation
import OSLog

nonisolated private let agentHookDeliveryLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "AgentHookDelivery"
)

extension CMUXCLI {
    /// Chooses the live wrapper PID for Codex while preserving legacy precedence for other agents.
    func preferredAgentHookEventPID(
        agentName: String,
        mappedPID: Int?,
        inferredPID: Int?
    ) -> Int? {
        agentName == "codex"
            ? inferredPID ?? mappedPID
            : mappedPID ?? inferredPID
    }

    /// Reports a persistently throttled hook failure without serializing raw transport details.
    func reportAgentHookFailure(
        stage: AgentHookFailureStage,
        agentName: String,
        sessionId: String,
        event: String,
        error: Error? = nil,
        store: ClaudeHookSessionStore,
        telemetry: CLISocketSentryTelemetry
    ) {
        guard (try? store.claimAgentHookFailureReport(
            agentName: agentName,
            stage: stage.rawValue,
            sessionId: sessionId
        )) == true else {
            return
        }
        let shortSessionId = String(sessionId.prefix(12))
        let errorType = error.map { String(reflecting: type(of: $0)) } ?? "unresolved-target"
        let reportableError = NSError(
            domain: "com.cmuxterm.cli.agent-hook.\(stage.rawValue)",
            code: 1,
            userInfo: ["underlying_error_type": errorType]
        )
        agentHookDeliveryLogger.error(
            "Agent hook failed stage=\(stage.rawValue, privacy: .public) event=\(event, privacy: .public) agent=\(agentName, privacy: .public) session=\(shortSessionId, privacy: .private(mask: .hash)) errorType=\(errorType, privacy: .private(mask: .hash))"
        )
        telemetry.captureError(
            stage: "agent-hook-\(stage.rawValue)",
            error: reportableError,
            data: [
                "agent": agentName,
                "hook_event": event,
                "has_session_id": !sessionId.isEmpty,
                "underlying_error_type": errorType,
            ],
            classificationError: error
        )
    }
}
