import CMUXAgentLaunch
import CmuxSettings
import Foundation

private let claudeTeamsForwardedEnvironmentKeys: [String] = [
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
    "CLAUDE_CODE_SANDBOXED",
    "CMUX_CLAUDE_TEAMS_SANDBOXED",
    "CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT",
    "CMUX_CLAUDE_TEAMS_CMUX_BIN",
    "CMUX_CLAUDE_TEAMS_TMUX_SHIM",
    "CMUX_CLAUDE_TEAMS_RESPAWN_ENV_B64",
    "TMUX",
]

/// Claude Teams can ask tmux to create a teammate with `new-window`. In
/// surface mode, keep that teammate in the caller's workspace and return a
/// stable tmux-shaped token for subsequent tmux commands.
extension CMUXCLI {
    /// Re-enters the Claude Teams launcher when a restored teammate was
    /// captured as a plain `claude` process. Claude's hook intentionally
    /// rewrites teammate launch metadata to that plain executable, so a direct
    /// restore would lose the tmux shim and could silently fall back to a real
    /// system tmux. Routing the resume through the current cmux binary rebuilds
    /// the validated shim and reapplies the persisted placement setting.
    func claudeTeamsRestoreInvocationIfNeeded(
        _ invocation: AgentRestoreInvocation,
        record: RestoreRecord,
        processEnvironment: [String: String]
    ) -> AgentRestoreInvocation {
        guard record.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude",
              record.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == AgentRestoreRequestMode.resumeAgent.rawValue.lowercased(),
              let checkpointID = record.checkpointID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkpointID.isEmpty,
              claudeTeamsRestoreMarkerPresent(record: record),
              record.launchCommand?.launcher?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                != "claudeteams" else {
            return invocation
        }

        let capturedArguments = record.launchCommand?.arguments ?? []
        let sourceArguments = capturedArguments.isEmpty
            ? invocation.arguments
            : capturedArguments
        guard !sourceArguments.isEmpty else { return invocation }
        let executablePath = resolvedExecutableURL()?.path
            ?? processEnvironment["CMUX_BUNDLED_CLI_PATH"]
            ?? "cmux"
        let routedArguments: [String]?
        switch AgentResumeArgv().launcherResolution(
            launcher: "claudeTeams",
            sessionId: checkpointID,
            executablePath: executablePath,
            arguments: sourceArguments
        ) {
        case .resolved(let arguments):
            routedArguments = arguments
        case .passthrough:
            routedArguments = nil
        }
        guard let routedArguments, !routedArguments.isEmpty else {
            return invocation
        }

        var environment = invocation.environment
        // The planner authorizes a direct `claude` wrapper. That token must not
        // leak into the fresh `cmux claude-teams` launch, whose wrapper owns its
        // own launch capture and session setup.
        environment.removeValue(forKey: "CMUX_AGENT_RESTORE_LAUNCH")
        environment.removeValue(forKey: "CMUX_CLAUDE_TEAMS_WRAPPER_LAUNCH")
        return AgentRestoreInvocation(
            arguments: routedArguments,
            workingDirectory: invocation.workingDirectory,
            environment: environment,
            preflightInvocations: invocation.preflightInvocations
        )
    }

    private func claudeTeamsRestoreMarkerPresent(record: RestoreRecord) -> Bool {
        var capturedEnvironment = record.launchCommand?.environment ?? [:]
        capturedEnvironment.merge(record.environment) { _, restored in restored }
        return capturedEnvironment["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == "1"
    }

    /// Returns the cmux/Claude variables that are safe and necessary to carry
    /// from the lead launcher into a teammate surface. Provider configuration
    /// (including PATH) comes from the signed transport snapshot; these values
    /// are the launch-control side of that snapshot and are intentionally
    /// copied only while the Claude Teams marker is present.
    func claudeTeamsRespawnControlEnvironment(
        processEnvironment: [String: String]
    ) -> [String: String] {
        guard isClaudeTeamsEnvironment(processEnvironment) else { return [:] }
        var forwarded: [String: String] = [:]
        for key in claudeTeamsForwardedEnvironmentKeys {
            guard let value = processEnvironment[key], isSafeEnvironmentValue(value) else { continue }
            forwarded[key] = value
        }

        // A restored teammate may not have the launcher's explicit snapshot
        // value. Carry the current setting into its next respawn so the choice
        // remains stable even when the parent `cmux claude-teams` process is
        // gone.
        forwarded["CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"] =
            claudeTeamsSpawnPlacement(processEnvironment: processEnvironment).rawValue
        return forwarded
    }

    /// Builds the startup environment for a teammate created by `new-window`.
    /// The tmux token is installed before the surface exists; all other values
    /// are copied from the lead's replay-safe transport and control context.
    func claudeTeamsSurfaceStartupEnvironment(
        aliasToken: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var startup = ClaudeTeamsRespawnEnvironmentTransport().decodedEnvironment(
            from: processEnvironment[ClaudeTeamsRespawnEnvironmentTransport.environmentKey]
        )
        startup.merge(
            claudeTeamsRespawnControlEnvironment(processEnvironment: processEnvironment)
        ) { _, incoming in incoming }
        startup["CMUX_CLAUDE_TEAMS_SPAWN_PLACEMENT"] = TeamsSpawnPlacement.surface.rawValue
        startup["TMUX_PANE"] = aliasToken

        // The lead normally supplies this path. The bundled path fallback keeps
        // a teammate launch functional when a shell stripped the inherited
        // variable before invoking the compatibility command.
        if startup["CMUX_CLAUDE_TEAMS_CMUX_BIN"] == nil,
           let executable = processEnvironment["CMUX_BUNDLED_CLI_PATH"]
                ?? resolvedExecutableURL()?.path {
            startup["CMUX_CLAUDE_TEAMS_CMUX_BIN"] = executable
        }
        return startup
    }

    private func isClaudeTeamsEnvironment(_ environment: [String: String]) -> Bool {
        environment["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == "1"
            || normalizedTmuxTarget(environment["CMUX_CLAUDE_TEAMS_CMUX_BIN"]) != nil
            || normalizedTmuxTarget(environment["CMUX_CLAUDE_TEAMS_TMUX_SHIM"]) != nil
    }

    private func isSafeEnvironmentValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
    }

    func tmuxCreateClaudeTeamsSurfaceWindow(
        workingDirectory: String?,
        title: String?,
        commandTokens: [String],
        printResult: Bool,
        format: String?,
        client: SocketClient
    ) throws {
        let target = try tmuxResolvePaneTarget(nil, client: client)
        let aliasToken = tmuxSurfaceAliasToken(surfaceId: UUID().uuidString)
        var params: [String: Any] = [
            "workspace_id": target.workspaceId,
            "pane_id": target.paneId,
            "focus": false,
            "startup_environment": claudeTeamsSurfaceStartupEnvironment(aliasToken: aliasToken),
        ]
        if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            params["working_directory"] = resolvePath(cwd)
        }
        let created = try client.sendV2(method: "surface.create", params: params)
        guard let surfaceId = created["surface_id"] as? String,
              !surfaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: String(
                localized: "cli.tmuxCompat.error.surfaceCreateMissingId",
                defaultValue: "surface.create did not return surface_id for Claude Teams teammate"
            ))
        }

        try tmuxRecordSurfaceAlias(
            aliasToken: aliasToken,
            workspaceId: target.workspaceId,
            surfaceId: surfaceId
        )

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? client.sendV2(method: "tab.action", params: [
                "workspace_id": target.workspaceId,
                "surface_id": surfaceId,
                "action": "rename",
                "title": title,
            ])
        }
        if let text = tmuxShellCommandText(commandTokens: commandTokens, cwd: workingDirectory) {
            _ = try client.sendV2(method: "surface.send_text", params: [
                "workspace_id": target.workspaceId,
                "surface_id": surfaceId,
                "text": text
            ])
        }
        guard printResult else { return }
        let context = try tmuxFormatContext(
            workspaceId: target.workspaceId,
            paneId: aliasToken,
            surfaceId: surfaceId,
            client: client
        )
        print(tmuxRenderFormat(format, context: context, fallback: aliasToken))
    }
}
