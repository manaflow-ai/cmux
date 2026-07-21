import Foundation

extension CMUXCLI {
    private static let agentHookAdmissionResponseTimeoutSeconds = 1
    static let agentHookDeclaredTimeoutSeconds = 3
    static let agentHookDeclaredTimeoutMilliseconds = agentHookDeclaredTimeoutSeconds * 1_000

    /// Builds a fail-open command that admits a non-decision hook to the app's
    /// ordered delivery queue. The hook process performs no downstream delivery.
    static func queuedAgentHookShellCommand(
        agent: String,
        subcommand: String,
        disableEnvironmentVariable: String
    ) -> String {
        let pidEnvironmentVariable = agentHookPIDEnvironmentVariable(agentName: agent)
        let executableEnvironmentVariable = agent == "claude"
            ? "CMUX_CLAUDE_HOOK_CMUX_BIN"
            : "CMUX_CODEX_HOOK_CMUX_BIN"
        return [
            "cmux_cli=\"${\(executableEnvironmentVariable):-${CMUX_BUNDLED_CLI_PATH:-}}\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "agent_pid=\"${\(pidEnvironmentVariable):-${PPID:-}}\"",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(disableEnvironmentVariable)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || echo '{}'; else \(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) \"$cmux_cli\" hooks enqueue \(agent) \(subcommand) 2>/dev/null || echo '{}'; fi; else echo '{}'; fi",
        ].joined(separator: "; ")
    }

    /// Sends one immutable hook event to the app-owned queue, then returns the
    /// agent's neutral response. Downstream CLI/socket work happens in the app.
    func enqueueAgentHook(commandArgs: [String], client: SocketClient) throws {
        guard commandArgs.count == 2 else {
            throw CLIError(message: "Usage: cmux hooks enqueue <agent> <subcommand>")
        }
        let agent = commandArgs[0].lowercased()
        let subcommand = commandArgs[1].lowercased()

        let processEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in Self.queuedAgentHookEnvironmentKeys {
            if let value = processEnvironment[key] {
                environment[key] = value
            }
        }
        let payload = String(
            data: FileHandle.standardInput.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        _ = try client.sendV2(
            method: "agent.hook.enqueue",
            params: [
                "agent": agent,
                "subcommand": subcommand,
                "payload": payload,
                "socket_path": client.socketPath,
                "environment": environment,
            ],
            responseTimeout: TimeInterval(Self.agentHookAdmissionResponseTimeoutSeconds)
        )
        print("{}")
    }

    private static let queuedAgentHookEnvironmentKeys = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "HOME", "LANG", "LC_ALL", "LC_CTYPE",
        "LOGNAME", "PATH", "PWD", "SHELL", "TMPDIR", "USER",
        "CMUX_AGENT_HOOK_STATE_DIR", "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
        "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_KIND",
        "CMUX_AGENT_MANAGED_SUBAGENT", "CMUX_BUNDLE_ID", "CMUX_CLAUDE_PID",
        "CMUX_CODEX_PID", "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
        "CMUX_SURFACE_ID", "CMUX_TAG", "CMUX_WORKSPACE_ID",
    ]

    private static func agentHookPIDEnvironmentVariable(agentName: String) -> String {
        let component = agentName.uppercased().replacingOccurrences(
            of: "[^A-Z0-9]", with: "_", options: .regularExpression
        )
        return "CMUX_\(component)_PID"
    }
}
