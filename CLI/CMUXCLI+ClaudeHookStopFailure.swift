import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String? = nil,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil,
        priority: Int? = nil
    ) throws {
        // The socket tokenizer opens a quoted token at a bare ' or ", so a
        // localized value such as "Erreur d'API" would swallow every option
        // after it (--tab included) and land on the selected workspace.
        // Plain values stay bare to keep the wire format unchanged.
        let needsQuoting = value.contains { "'\"\\\n\r".contains($0) }
        let wireValue = needsQuoting ? socketQuote(value) : value
        var cmd = "set_status \(Self.claudeCodeStatusKey) \(wireValue) --icon=\(icon) --color=\(color)"
        if let priority {
            cmd += " --priority=\(priority)"
        }
        cmd += " --tab=\(workspaceId)\(socketPanelOption(surfaceId))"
        if let pid,
           ProcessInfo.processInfo.environment[agentHookRelayOriginEnvironmentKey] != "1" {
            cmd += " --pid=\(pid)"
        }
        _ = try client.send(command: cmd)
    }

    /// Shows a turn that Claude Code ended on an API error (`StopFailure`)
    /// with the same red error treatment other agents use, so the pane never
    /// keeps a stale "Running" pill and the reason is visible at a glance.
    func setClaudeStopFailureStatus(
        _ failure: ClaudeStopFailure,
        client: SocketClient,
        workspaceId: String,
        surfaceId: String
    ) throws {
        try setClaudeStatus(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            value: claudeStopFailureStatusValue(failure),
            icon: "exclamationmark.triangle.fill",
            color: "#FF453A",
            priority: 100
        )
    }

    /// Notification subtitle and body for a `StopFailure` turn. The body is
    /// the API's own message so the user sees exactly what failed.
    func claudeStopFailureSummary(_ failure: ClaudeStopFailure) -> (subtitle: String, body: String) {
        let body = failure.message.map { truncate($0, maxLength: 200) } ?? String(
            localized: "agent.claude.stopFailure.body.generic",
            defaultValue: "Claude Code stopped on an API error"
        )
        return (claudeStopFailureStatusValue(failure), body)
    }

    func claudeStopFailureStatusValue(_ failure: ClaudeStopFailure) -> String {
        switch failure.reason {
        case .usageLimit:
            guard let resetsAt = failure.resetsAt else {
                return String(localized: "agent.claude.stopFailure.status.usageLimit", defaultValue: "Usage limit")
            }
            return String.localizedStringWithFormat(
                String(localized: "agent.claude.stopFailure.status.usageLimitResets", defaultValue: "Usage limit, resets %@"),
                resetsAt
            )
        case .rateLimited:
            return String(localized: "agent.claude.stopFailure.status.rateLimited", defaultValue: "Rate limited")
        case .connectionDropped:
            return String(localized: "agent.claude.stopFailure.status.connectionDropped", defaultValue: "Connection dropped")
        case .overloaded:
            return String(localized: "agent.claude.stopFailure.status.overloaded", defaultValue: "API overloaded")
        case .authentication:
            return String(localized: "agent.claude.stopFailure.status.authentication", defaultValue: "Auth error")
        case .billing:
            return String(localized: "agent.claude.stopFailure.status.billing", defaultValue: "Billing error")
        case .outputLimit:
            return String(localized: "agent.claude.stopFailure.status.outputLimit", defaultValue: "Output limit")
        case .apiError:
            return String(localized: "agent.claude.stopFailure.status.apiError", defaultValue: "API error")
        }
    }
}
