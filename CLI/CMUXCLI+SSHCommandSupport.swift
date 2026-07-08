import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Inserts `-o RemoteCommand=none` right after the `ssh` executable so a
    /// host-configured (or caller-supplied) `RemoteCommand` cannot conflict
    /// with the command-line remote command this invocation appends — OpenSSH
    /// aborts on that combination ("Cannot execute command-line and remote
    /// command.", issue #7246) and honors the first value per option. Only
    /// for invocations that pass their own command; the interactive session
    /// hop keeps its explicit `-o RemoteCommand=<bootstrap>`.
    internal func sshArgumentsOverridingHostRemoteCommand(_ arguments: [String]) -> [String] {
        guard arguments.first == "ssh" else {
            return SSHHostConfiguredRemoteCommand().overrideArguments + arguments
        }
        return [arguments[0]] + SSHHostConfiguredRemoteCommand().overrideArguments + arguments.dropFirst()
    }

    internal func openSSHLocalCommandValue(shellScript: String?) -> String? {
        guard let shellScript else { return nil }
        let trimmed = shellScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return openSSHCommandOptionValue(posixShellCommand(trimmed))
    }

    internal func openSSHRemoteCommandValue(shellScript: String) -> String {
        openSSHCommandOptionValue(posixShellCommand(shellScript))
    }

    internal func posixShellCommand(_ shellScript: String) -> String {
        "/bin/sh -c " + shellQuote(shellScript)
    }

    internal func openSSHCommandOptionValue(_ command: String) -> String {
        command.replacingOccurrences(of: "%", with: "%%")
    }

    internal func normalizedSSHIdentityPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                return expanded
            }
        }
        return trimmed
    }

    /// Joins self-delimiting POSIX shell snippets with one space; this is not a general shell combiner.
    internal func combinedLocalShellScript(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { raw -> String? in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: " ")
    }

    internal func sshRemoteConfigureParams(
        workspaceId: String,
        sshOptions: SSHCommandOptions,
        remoteSSHOptions: [String],
        relayID: String,
        relayToken: String,
        terminalStartupCommand: String,
        foregroundAuthToken: String?,
        autoConnect: Bool,
        persistentDaemonSlot: String?,
        managedCloudVMID: String?
    ) -> [String: Any] {
        var configureParams: [String: Any] = [
            "workspace_id": workspaceId,
            "destination": sshOptions.destination,
            "auto_connect": autoConnect,
        ]
        if let foregroundAuthToken {
            configureParams["foreground_auth_token"] = foregroundAuthToken
        }
        if let port = sshOptions.port {
            configureParams["port"] = port
        }
        if let identityFile = normalizedSSHIdentityPath(sshOptions.identityFile) {
            configureParams["identity_file"] = identityFile
        }
        if !remoteSSHOptions.isEmpty {
            configureParams["ssh_options"] = remoteSSHOptions
        }
        if let agentSocketPath = sshOptions.agentSocketPath {
            configureParams["ssh_auth_sock"] = agentSocketPath
        }
        if sshOptions.remoteRelayPort > 0 {
            configureParams["relay_port"] = sshOptions.remoteRelayPort
            configureParams["relay_id"] = relayID
            configureParams["relay_token"] = relayToken
            configureParams["local_socket_path"] = sshOptions.localSocketPath
        }
        if let daemon = sshOptions.daemonWebSocketEndpoint {
            configureParams["daemon_websocket_url"] = daemon.url
            configureParams["daemon_websocket_headers"] = daemon.headers
            configureParams["daemon_websocket_token"] = daemon.token
            configureParams["daemon_websocket_session_id"] = daemon.sessionId
            configureParams["daemon_websocket_expires_at_unix"] = daemon.expiresAtUnix
            configureParams["local_socket_path"] = sshOptions.localSocketPath
        }
        if let managedCloudVMID {
            configureParams["managed_cloud_vm_id"] = managedCloudVMID
        }
        configureParams["terminal_startup_command"] = terminalStartupCommand
        if sshOptions.skipDaemonBootstrap {
            configureParams["skip_daemon_bootstrap"] = true
        }
        if let persistentDaemonSlot {
            configureParams["preserve_after_terminal_exit"] = true
            configureParams["persistent_daemon_slot"] = persistentDaemonSlot
        }
        return configureParams
    }

    internal func runSSHPaneScope(
        sshOptions: SSHCommandOptions,
        relayID: String,
        relayToken: String,
        client: SocketClient,
        jsonOutput: Bool,
        remoteSSHOptions: [String],
        initialSSHStartupCommand: String,
        reusableTerminalStartupCommand: String,
        configuredForegroundAuthToken: String?,
        autoConnect: Bool,
        persistentDaemonSlot: String?,
        managedCloudVMID: String?
    ) throws -> Never {
        guard !jsonOutput else {
            throw CLIError(message: "ssh --pane cannot emit --json output (this pane becomes the interactive ssh session)")
        }
        let environment = ProcessInfo.processInfo.environment
        let paneWorkspaceId = environment["CMUX_WORKSPACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let paneSurfaceId = environment["CMUX_SURFACE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let paneWorkspaceId, !paneWorkspaceId.isEmpty,
              let paneSurfaceId, !paneSurfaceId.isEmpty else {
            throw CLIError(
                message: "ssh --pane must run inside a cmux terminal pane (CMUX_WORKSPACE_ID/CMUX_SURFACE_ID are not set)"
            )
        }

        var configureParams = sshRemoteConfigureParams(
            workspaceId: paneWorkspaceId,
            sshOptions: sshOptions,
            remoteSSHOptions: remoteSSHOptions,
            relayID: relayID,
            relayToken: relayToken,
            terminalStartupCommand: reusableTerminalStartupCommand,
            foregroundAuthToken: configuredForegroundAuthToken,
            autoConnect: autoConnect,
            persistentDaemonSlot: persistentDaemonSlot,
            managedCloudVMID: managedCloudVMID
        )
        configureParams["scope"] = "pane"
        configureParams["seed_surface_id"] = paneSurfaceId

        let result = try client.sendV2(method: "workspace.remote.configure", params: configureParams)
        let startupCommand: String
        if (result["joined_existing"] as? Bool) == true {
            guard let joinedStartupCommand = result["startup_command"] as? String,
                  !joinedStartupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: "ssh --pane joined an existing connection but cmux did not return a startup command")
            }
            startupCommand = joinedStartupCommand
        } else {
            startupCommand = initialSSHStartupCommand
        }
        client.close()
        try execInteractiveProgram(launchPath: "/bin/sh", arguments: ["-c", startupCommand])
    }
}
