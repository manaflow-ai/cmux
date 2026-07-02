import Foundation
import CmuxCore

extension Workspace {
    var localPersistentPTYWorkspaceIdentity: UUID {
        restoredLocalPersistentPTYWorkspaceId ?? id
    }

    func configureLocalPersistentPTYServerIfNeeded(autoConnect: Bool = true) {
        if let remoteConfiguration, remoteConfiguration.transport != .local {
            return
        }
        let configuration = WorkspaceRemoteConfiguration(
            transport: .local,
            destination: "local",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            foregroundAuthToken: nil,
            agentSocketPath: nil,
            daemonWebSocketEndpoint: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: Self.localPersistentPTYSlot(workspaceId: localPersistentPTYWorkspaceIdentity),
            skipDaemonBootstrap: false
        )
        if remoteConfiguration == configuration {
            return
        }
        configureRemoteConnection(configuration, autoConnect: autoConnect)
    }

    func localPersistentPTYStartupCommand(
        panelId: UUID,
        workingDirectory: String?,
        explicitCommand: String?,
        startupEnvironment: [String: String]
    ) -> String? {
        guard remoteConfiguration?.transport == .local else { return nil }
        let sessionID = Self.defaultSSHPTYSessionID(
            workspaceId: localPersistentPTYWorkspaceIdentity,
            panelId: panelId
        )
        let remoteCommand = Self.localPersistentPTYRemoteCommand(
            workingDirectory: workingDirectory,
            explicitCommand: explicitCommand,
            startupEnvironment: startupEnvironment
        )
        return SSHPTYAttachStartupCommandBuilder.command(
            sessionID: sessionID,
            remoteCommand: remoteCommand,
            requireExisting: false
        )
    }

    private nonisolated static func localPersistentPTYSlot(workspaceId: UUID) -> String {
        "local-\(workspaceId.uuidString.lowercased())"
    }

    private nonisolated static func localPersistentPTYRemoteCommand(
        workingDirectory: String?,
        explicitCommand: String?,
        startupEnvironment: [String: String]
    ) -> String {
        var lines: [String] = [
            "set +u",
        ]
        for key in localPersistentPTYForwardedEnvironmentKeys {
            lines.append("cmux_forwarded_value=__CMUX_ENV_SH_\(key)__")
            lines.append("if [ -n \"$cmux_forwarded_value\" ]; then export \(key)=\"$cmux_forwarded_value\"; fi")
        }
        for (key, value) in startupEnvironment.sorted(by: { $0.key < $1.key }) {
            guard isSafeShellEnvironmentKey(key) else { continue }
            lines.append("export \(key)=\(shellQuote(value))")
        }
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            lines.append("cd \(shellQuote(workingDirectory)) || exit $?")
        }
        if let explicitCommand = explicitCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitCommand.isEmpty {
            lines.append("exec /bin/sh -lc \(shellQuote(explicitCommand))")
        } else {
            lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static let localPersistentPTYForwardedEnvironmentKeys: [String] = [
        "CMUX_BUNDLE_ID",
        "CMUX_BUNDLED_CLI_PATH",
        "CMUX_CLAUDE_HOOKS_DISABLED",
        "CMUX_CLAUDE_WRAPPER_SHIM",
        "CMUX_CLAUDE_WRAPPER_SHIM_ROOT",
        "CMUX_CUSTOM_CLAUDE_PATH",
        "CMUX_PORT",
        "CMUX_PORT_END",
        "CMUX_PORT_RANGE",
        "CMUX_SHELL_INTEGRATION",
        "CMUX_SHELL_INTEGRATION_DIR",
        "CMUX_SOCKET_PATH",
        "CMUX_SURFACE_ID",
        "CMUX_WORKSPACE_ID",
        "PATH",
    ]

    private nonisolated static func isSafeShellEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 95
        }
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
