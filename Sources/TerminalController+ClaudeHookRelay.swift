import Foundation

private enum ClaudeHookRelayStrings {
    static let invalidEvent = String(localized: "socket.claudeHookRelay.invalidEvent", defaultValue: "Missing or invalid event")
    static let invalidPayload = String(localized: "socket.claudeHookRelay.invalidPayload", defaultValue: "Missing or invalid payload")
    static let hookFailed = String(localized: "socket.claudeHookRelay.hookFailed", defaultValue: "Claude hook failed")
}

extension TerminalController {
    nonisolated func v2ClaudeHook(params: [String: Any]) -> V2CallResult {
        guard let event = v2String(params, "event") else {
            return .err(code: "invalid_params", message: ClaudeHookRelayStrings.invalidEvent, data: nil)
        }
        guard let payload = params["payload"] as? String else {
            return .err(code: "invalid_params", message: ClaudeHookRelayStrings.invalidPayload, data: nil)
        }

        var arguments = [
            event,
        ]
        if let workspaceId = v2String(params, "workspace_id") {
            arguments += ["--workspace", workspaceId]
        }
        if let surfaceId = v2String(params, "surface_id") {
            arguments += ["--surface", surfaceId]
        }

        return runClaudeHookRelay(
            commandArgs: arguments,
            payload: payload,
            socketPath: socketServer.currentSocketPath,
            socketPassword: configuredSocketPasswordForSelfConnection()
        )
    }

    nonisolated func runClaudeHookRelay(
        commandArgs: [String],
        payload: String,
        socketPath: String,
        socketPassword: String? = nil,
        cli: CMUXCLI = CMUXCLI(args: [])
    ) -> V2CallResult {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = cli.optionValue(hookArgs, name: "--workspace")
        let hookSurfaceFlag = cli.optionValue(hookArgs, name: "--surface")
        let client = SocketClient(path: socketPath)
        let telemetry = CLISocketSentryTelemetry(
            command: "hooks",
            commandArgs: ["claude"] + commandArgs,
            socketPath: socketPath,
            processEnv: ProcessInfo.processInfo.environment
        )
        do {
            try client.connect()
            defer { client.close() }
            try cli.authenticateClientIfNeeded(
                client,
                explicitPassword: socketPassword,
                socketPath: socketPath
            )
            var stdout = ""
            try cli.runClaudeHookCore(
                subcommand: subcommand,
                hookArgs: hookArgs,
                rawInput: payload,
                client: client,
                telemetry: telemetry,
                socketPassword: socketPassword,
                workspaceArg: hookWsFlag,
                surfaceArg: hookSurfaceFlag,
                hookWorkspaceFlagIsExplicit: hookWsFlag != nil,
                hookSurfaceFlagIsExplicit: hookSurfaceFlag != nil,
                preferCallerTTYRouting: hookWsFlag == nil && hookSurfaceFlag == nil,
                stdout: { line in
                    stdout += line
                    stdout += "\n"
                }
            )
            if stdout.isEmpty {
                return .ok([:])
            }
            return .ok(["stdout": stdout])
        } catch {
            return .err(
                code: "hook_failed",
                message: ClaudeHookRelayStrings.hookFailed,
                data: ["error": error.localizedDescription]
            )
        }
    }
}
