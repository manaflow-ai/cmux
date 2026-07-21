import Foundation

extension CMUXCLI {
    private static let deferredHookResponseTimeoutSeconds = 15
    // Genuine detached-process lifetime cap; admission returns before this
    // deadline starts and never polls it for synchronization.
    private static let deferredHookLifetimeSeconds = 30

    /// Builds the shared fail-open admission path for an installed lifecycle
    /// hook. Decision hooks deliberately do not use this path because the agent
    /// consumes their stdout or exit status synchronously.
    static func fireAndForgetAgentHookShellCommand(_ command: String, for def: AgentHookDef) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let deliverySetup = [
            "set -- \"$cmux_cli\"",
            "if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then set -- \"$@\" --socket \"$CMUX_SOCKET_PATH\"; fi",
            "set -- \"$@\" \(routedArguments)",
        ].joined(separator: "; ")
        let admission = boundedFireAndForgetHookShellCommand(
            deliveryArgumentSetup: deliverySetup,
            agentName: def.name,
            pidEnvironmentVariable: agentHookPIDEnvironmentVariable(agentName: def.name)
        )
        return [
            "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then \(admission); else echo '{}'; fi",
        ].joined(separator: "; ")
    }

    /// Stages stdin before returning `{}` and gives the detached delivery a
    /// bounded lifetime. `deliveryArgumentSetup` must populate the shell's
    /// positional arguments with the executable followed by its arguments.
    static func boundedFireAndForgetHookShellCommand(
        deliveryArgumentSetup: String,
        agentName: String,
        pidEnvironmentVariable: String
    ) -> String {
        let watchdog = [
            "timer=\"\"",
            "trap \"if [ -n \\\"\\$timer\\\" ]; then kill \\\"\\$timer\\\" 2>/dev/null || true; fi\" 0",
            "trap \"exit 0\" 1 2 15",
            "sleep \(deferredHookLifetimeSeconds) & timer=\"$!\"",
            "wait \"$timer\" 2>/dev/null || exit 0",
            "timer=\"\"",
            "trap - 0 1 2 15",
            "kill \"$child\" 2>/dev/null || true",
        ].joined(separator: "; ")
        let runner = "payload=\"$1\"; shift; \"$@\" <\"$payload\" >/dev/null 2>&1 & child=\"$!\"; ( \(watchdog) ) & watchdog=\"$!\"; wait \"$child\" 2>/dev/null || true; kill \"$watchdog\" 2>/dev/null || true; wait \"$watchdog\" 2>/dev/null || true; rm -f \"$payload\""
        let safeAgentName = agentName.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        return [
            "agent_pid=\"${\(pidEnvironmentVariable):-${PPID:-}}\"",
            "payload=\"$(mktemp \"${TMPDIR:-/tmp}/cmux-\(safeAgentName)-hook.XXXXXX\" 2>/dev/null || mktemp -t cmux-\(safeAgentName)-hook 2>/dev/null)\" || { echo '{}'; exit 0; }",
            "cat >\"$payload\" || { rm -f \"$payload\"; echo '{}'; exit 0; }",
            deliveryArgumentSetup,
            "\(pidEnvironmentVariable)=\"$agent_pid\" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(deferredHookResponseTimeoutSeconds) nohup sh -c '\(runner)' cmux-agent-hook \"$payload\" \"$@\" >/dev/null 2>&1 & echo '{}'",
        ].joined(separator: "; ")
    }

    private static func agentHookPIDEnvironmentVariable(agentName: String) -> String {
        let component = agentName.uppercased().replacingOccurrences(
            of: "[^A-Z0-9]", with: "_", options: .regularExpression
        )
        return "CMUX_\(component)_PID"
    }
}
