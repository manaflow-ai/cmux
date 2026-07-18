import CMUXAgentLaunch
import Foundation

@MainActor
extension TerminalController {
    func codexTranscriptMonitorOwnership(
        for target: CodexTranscriptMonitorTarget
    ) -> CodexTranscriptMonitorOwnership {
        var params: [String: Any] = ["workspace_id": target.workspaceID.uuidString]
        if let surfaceID = target.surfaceID { params["surface_id"] = surfaceID.uuidString }
        switch v2AgentResolveDeliveryTarget(params: params) {
        case .ok(let rawResult):
            guard let result = rawResult as? [String: Any],
                  let workspaceRaw = result["workspace_id"] as? String,
                  let workspaceID = UUID(uuidString: workspaceRaw) else {
                return .unknown
            }
            let surfaceID = (result["surface_id"] as? String).flatMap(UUID.init(uuidString:))
            return .alive(CodexTranscriptMonitorTarget(
                workspaceID: workspaceID,
                surfaceID: surfaceID ?? target.surfaceID
            ))
        case .err(let code, _, _):
            return code == "not_found" ? .gone : .unknown
        }
    }

    func publishCodexTranscriptMonitorUpdate(
        _ update: CodexTranscriptMonitorUpdate,
        request _: CodexTranscriptMonitorRequest,
        target: CodexTranscriptMonitorTarget
    ) {
        switch update {
        case .userInput(let input):
            let subtitle = String(localized: "agent.codex.input.subtitle.waiting", defaultValue: "Waiting")
            let body = input.question ?? String(
                localized: "agent.codex.input.body.needsInput",
                defaultValue: "Codex is asking a question"
            )
            publishCodexTranscriptMonitorNotification(
                subtitle: subtitle,
                body: body,
                target: target
            )
            let status = String(localized: "agent.codex.input.status.needsInput", defaultValue: "Codex needs input")
            publishCodexTranscriptMonitorStatus(
                status,
                icon: "bell.fill",
                color: "#4C8DFF",
                target: target
            )

        case .failure(let failure):
            let presentation = codexTranscriptMonitorFailurePresentation(failure)
            publishCodexTranscriptMonitorNotification(
                subtitle: presentation.subtitle,
                body: presentation.body,
                target: target
            )
            publishCodexTranscriptMonitorStatus(
                presentation.status,
                icon: "exclamationmark.triangle.fill",
                color: "#FF453A",
                target: target
            )
        }
    }

    private func publishCodexTranscriptMonitorNotification(
        subtitle: String,
        body: String,
        target: CodexTranscriptMonitorTarget
    ) {
        guard let surfaceID = target.surfaceID else { return }
        let payload = ["Codex", subtitle, body]
            .map(Self.codexTranscriptMonitorNotificationField)
            .joined(separator: "|")
        _ = handleSocketLine(
            "notify_target \(target.workspaceID.uuidString) \(surfaceID.uuidString) \(payload)"
        )
    }

    private func publishCodexTranscriptMonitorStatus(
        _ status: String,
        icon: String,
        color: String,
        target: CodexTranscriptMonitorTarget
    ) {
        let panel = target.surfaceID.map { " --panel=\($0.uuidString)" } ?? ""
        _ = handleSocketLine(
            "set_status codex \(Self.codexTranscriptMonitorSingleLine(status)) "
                + "--icon=\(icon) --color=\(color) --priority=100 "
                + "--tab=\(target.workspaceID.uuidString)\(panel)"
        )
    }

    private func codexTranscriptMonitorFailurePresentation(
        _ failure: CodexTranscriptMonitorFailure
    ) -> (status: String, subtitle: String, body: String) {
        let fallbackMessage: String
        switch failure.kind {
        case .reported:
            fallbackMessage = String(
                localized: "agent.codex.error.defaultMessage",
                defaultValue: "Codex reported an error"
            )
        case .missingFinalResponse:
            fallbackMessage = String(
                localized: "agent.codex.error.noFinalResponse",
                defaultValue: "Codex ended before sending a final response"
            )
        }
        let message = failure.message ?? fallbackMessage
        let signal = [
            message,
            failure.codexErrorInfo,
            failure.additionalDetails,
            failure.isStreamError ? "stream_error" : nil,
        ].compactMap { $0 }.joined(separator: " ").lowercased()

        let subtitle: String
        let status: String
        if signal.contains("usage_limit") || signal.contains("usage limit")
            || signal.contains("rate_limit") || signal.contains("rate limit")
            || signal.contains("credits") {
            subtitle = String(localized: "agent.codex.error.subtitle.rateLimit", defaultValue: "Rate limit")
            status = String(localized: "agent.codex.error.status.rateLimit", defaultValue: "Codex rate limit")
        } else if signal.contains("unauthorized") || signal.contains("auth")
                    || signal.contains("access token") || signal.contains("sign in")
                    || signal.contains("login") {
            subtitle = String(localized: "agent.codex.error.subtitle.auth", defaultValue: "Auth error")
            status = String(localized: "agent.codex.error.status.auth", defaultValue: "Codex auth error")
        } else if signal.contains("response_stream") || signal.contains("stream disconnected")
                    || signal.contains("connection") || signal.contains("network")
                    || signal.contains("offline") || signal.contains("timed out")
                    || signal.contains("timeout") {
            subtitle = String(localized: "agent.codex.error.subtitle.network", defaultValue: "Network error")
            status = String(localized: "agent.codex.error.status.network", defaultValue: "Codex network error")
        } else {
            subtitle = String(localized: "agent.codex.error.subtitle.generic", defaultValue: "Error")
            status = String(localized: "agent.codex.error.status.generic", defaultValue: "Codex error")
        }
        let body = String(Self.codexTranscriptMonitorSingleLine(
            failure.additionalDetails ?? message
        ).prefix(220))
        return (status, subtitle, body)
    }

    private nonisolated static func codexTranscriptMonitorNotificationField(_ value: String) -> String {
        codexTranscriptMonitorSingleLine(value).replacingOccurrences(of: "|", with: "¦")
    }

    private nonisolated static func codexTranscriptMonitorSingleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
