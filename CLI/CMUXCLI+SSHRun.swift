import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - cmux ssh command and option parsing
extension CMUXCLI {
    struct SSHCommandOptions {
        let destination: String
        let displayDestination: String
        let port: Int?
        let identityFile: String?
        let workspaceName: String?
        let windowRaw: String?
        let noFocus: Bool
        let sshOptions: [String]
        let extraArguments: [String]
        let agentSocketPath: String?
        let localSocketPath: String
        let remoteRelayPort: Int
        /// True when the remote is a cloud VM with cmuxd-remote pre-baked in the image.
        /// Set by `cmux vm new/shell/attach`; false for plain `cmux ssh`.
        let skipDaemonBootstrap: Bool

        init(
            destination: String,
            displayDestination: String? = nil,
            port: Int?,
            identityFile: String?,
            workspaceName: String?,
            windowRaw: String? = nil,
            noFocus: Bool,
            sshOptions: [String],
            extraArguments: [String],
            agentSocketPath: String? = nil,
            localSocketPath: String,
            remoteRelayPort: Int,
            skipDaemonBootstrap: Bool = false
        ) {
            self.destination = destination
            self.displayDestination = displayDestination ?? destination
            self.port = port
            self.identityFile = identityFile
            self.workspaceName = workspaceName
            self.windowRaw = windowRaw
            self.noFocus = noFocus
            self.sshOptions = sshOptions
            self.extraArguments = extraArguments
            self.agentSocketPath = agentSocketPath
            self.localSocketPath = localSocketPath
            self.remoteRelayPort = remoteRelayPort
            self.skipDaemonBootstrap = skipDaemonBootstrap
        }
    }

    func runSSH(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        // Use the socket path from this invocation (supports --socket overrides).
        let localSocketPath = client.socketPath
        let remoteRelayPort = generateRemoteRelayPort()
        let relayID = UUID().uuidString.lowercased()
        let relayToken = try randomHex(byteCount: 32)
        let sshOptions = try parseSSHCommandOptions(
            commandArgs,
            localSocketPath: localSocketPath,
            remoteRelayPort: remoteRelayPort,
            windowOverride: windowOverride
        )
        try runSSHWithOptions(
            sshOptions,
            relayID: relayID,
            relayToken: relayToken,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    /// Generic "open a workspace, SSH into the remote, bootstrap cmuxd-remote, forward socket,
    /// drop the user in a shell" pipeline. The inner loop of `cmux ssh`; also called from
    /// `cmux vm new`/`shell`/`attach` so cloud VMs reuse the exact same bootstrap.
    func runSSHWithOptions(
        _ sshOptions: SSHCommandOptions,
        relayID: String,
        relayToken: String,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        vmIDForSplitAttach: String? = nil
    ) throws {
        let sshStartedAt = Date()
        func logSSHTiming(_ stage: String, extra: String = "") {
            let elapsedMs = Int(Date().timeIntervalSince(sshStartedAt) * 1000)
            let suffix = extra.isEmpty ? "" : " \(extra)"
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.displayDestination) relayPort=\(sshOptions.remoteRelayPort) " +
                "stage=\(stage) elapsedMs=\(elapsedMs)\(suffix)"
            )
        }

        logSSHTiming("parsed")
        let terminfoSource = localXtermGhosttyTerminfoSource()
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.displayDestination) relayPort=\(sshOptions.remoteRelayPort) " +
            "stage=terminfo elapsedMs=0 mode=deferred term=xterm-256color " +
            "source=\(terminfoSource == nil ? 0 : 1)"
        )
        let shellFeaturesValue = scopedGhosttyShellFeaturesValue()
        let remoteSSHOptions = effectiveSSHOptions(
            sshOptions.sshOptions,
            remoteRelayPort: sshOptions.remoteRelayPort
        )
        let controlPathPreflightShellFunction = sshControlPathPreflightShellFunction(options: sshOptions)
        let initialSSHCommand = buildSSHCommandText(sshOptions)
        // For VM workspaces (Freestyle), skip the interactive bootstrap script: the russh
        // gateway forwards shell-request PTYs but stalls on exec-channel I/O, and the bootstrap
        // script is only meaningful if cmuxd-remote is participating. Let ssh open a plain
        // interactive shell instead.
        let remoteTerminalBootstrapScript: String?
        if sshOptions.skipDaemonBootstrap {
            remoteTerminalBootstrapScript = nil
        } else {
            remoteTerminalBootstrapScript = sshOptions.extraArguments.isEmpty
                ? buildInteractiveRemoteShellScript(
                    remoteRelayPort: sshOptions.remoteRelayPort,
                    shellFeatures: shellFeaturesValue,
                    terminfoSource: terminfoSource
                )
                : nil
        }
        let remoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript
        )
        let deferredRemoteReconnectToken = UUID().uuidString.lowercased()
        let deferredRemoteReconnectCommandScript = deferredRemoteReconnectLocalCommandScript(
            in: remoteSSHOptions,
            localCLIPath: resolvedExecutableURL()?.path,
            foregroundAuthToken: deferredRemoteReconnectToken
        )
        let sshConnectionTimingCommandScript = sshConnectionTimingLocalCommandScript(
            target: sshOptions.displayDestination,
            relayPort: sshOptions.remoteRelayPort
        )
        let combinedLocalCommandScript = combinedLocalShellScript([
            deferredRemoteReconnectCommandScript,
            sshConnectionTimingCommandScript,
        ])
        let configuredForegroundAuthToken = deferredRemoteReconnectCommandScript == nil
            ? nil
            : deferredRemoteReconnectToken
        let usesPersistentSSHPTY =
            !sshOptions.skipDaemonBootstrap &&
            sshOptions.extraArguments.isEmpty &&
            remoteTerminalBootstrapScript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            deferredRemoteReconnectCommandScript != nil
        let persistentDaemonSlot = usesPersistentSSHPTY
            ? "ssh-\(UUID().uuidString.lowercased())"
            : nil
        let startupInitialSSHCommand = buildSSHCommandText(
            sshOptions,
            localCommandScript: combinedLocalCommandScript
        )
        let startupRemoteTerminalSSHCommand = buildSSHCommandText(
            sshOptions,
            remoteBootstrapScript: remoteTerminalBootstrapScript,
            localCommandScript: combinedLocalCommandScript
        )
        var initialSSHStartupCommand: String
        var remoteTerminalSSHStartupCommand: String
        if let remoteTerminalBootstrapScript, !remoteTerminalBootstrapScript.isEmpty {
            initialSSHStartupCommand = try buildBootstrapSSHStartupCommand(
                options: sshOptions,
                remoteBootstrapScript: remoteTerminalBootstrapScript,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort,
                localCommandScript: combinedLocalCommandScript,
                controlPathPreflightShellFunction: controlPathPreflightShellFunction
            )
            remoteTerminalSSHStartupCommand = buildReusableBootstrapSSHStartupCommand(
                options: sshOptions,
                remoteBootstrapScript: remoteTerminalBootstrapScript,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort,
                localCommandScript: combinedLocalCommandScript,
                controlPathPreflightShellFunction: controlPathPreflightShellFunction
            )
        } else {
            initialSSHStartupCommand = try buildSSHStartupCommand(
                sshCommand: startupInitialSSHCommand,
                shellFeatures: "",
                remoteRelayPort: sshOptions.remoteRelayPort,
                controlPathPreflightShellFunction: controlPathPreflightShellFunction
            )
            remoteTerminalSSHStartupCommand = buildReusableSSHStartupCommand(
                sshCommand: startupRemoteTerminalSSHCommand,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: sshOptions.remoteRelayPort,
                controlPathPreflightShellFunction: controlPathPreflightShellFunction
            )
        }
        if usesPersistentSSHPTY,
           let remoteTerminalBootstrapScript {
            let ptyStartupCommand = buildReusableForegroundAuthThenSSHPTYAttachStartupCommand(
                options: sshOptions,
                remoteShellCommand: remoteTerminalBootstrapScript,
                localCommandScript: combinedLocalCommandScript,
                controlPathPreflightShellFunction: controlPathPreflightShellFunction
            )
            initialSSHStartupCommand = ptyStartupCommand
            remoteTerminalSSHStartupCommand = ptyStartupCommand
        }
        let reusableTerminalStartupCommand: String
        if let vmIDForSplitAttach,
           sshOptions.skipDaemonBootstrap {
            let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
            let splitAttachCommand = "\(shellQuote(executablePath)) vm ssh-attach --id \(shellQuote(vmIDForSplitAttach))"
            reusableTerminalStartupCommand = buildReusableSSHStartupCommand(
                sshCommand: splitAttachCommand,
                shellFeatures: shellFeaturesValue,
                remoteRelayPort: 0
            )
        } else {
            reusableTerminalStartupCommand = remoteTerminalSSHStartupCommand
        }
        cliDebugLog(
            "cli.ssh.start target=\(sshOptions.displayDestination) port=\(sshOptions.port.map(String.init) ?? "nil") " +
            "relayPort=\(sshOptions.remoteRelayPort) localSocket=\(sshOptions.localSocketPath) " +
            "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
            "workspaceName=\(sshOptions.workspaceName?.replacingOccurrences(of: " ", with: "_") ?? "nil") " +
            "extraArgs=\(sshOptions.extraArguments.count)"
        )

        var workspaceCreateParams: [String: Any] = [
            "initial_command": initialSSHStartupCommand,
        ]
        if let agentSocketPath = sshOptions.agentSocketPath {
            workspaceCreateParams["initial_env"] = [
                "SSH_AUTH_SOCK": agentSocketPath,
            ]
        }
        try applyWindowOrCallerContext(to: &workspaceCreateParams, client: client, windowRaw: sshOptions.windowRaw)

        let workspaceCreateStartedAt = Date()
        let workspaceCreate = try client.sendV2(method: "workspace.create", params: workspaceCreateParams)
        guard let workspaceId = workspaceCreate["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        let rawWorkspaceInitialSurfaceId = (workspaceCreate["surface_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var workspaceInitialSurfaceId = rawWorkspaceInitialSurfaceId?.isEmpty == false
            ? rawWorkspaceInitialSurfaceId
            : nil
        if usesPersistentSSHPTY && workspaceInitialSurfaceId == nil {
            do {
                workspaceInitialSurfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
            } catch {
                do {
                    _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
                } catch {
                    let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                    FileHandle.standardError.write(Data(warning.utf8))
                }
                throw CLIError(
                    message: "cmux could not resolve the initial terminal surface for persistent SSH PTY startup"
                )
            }
        }
        let workspaceWindowId = (workspaceCreate["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cliDebugLog(
            "cli.ssh.workspace.created workspace=\(String(workspaceId.prefix(8))) " +
            "window=\(workspaceWindowId.map { String($0.prefix(8)) } ?? "nil")"
        )
        cliDebugLog(
            "cli.ssh.timing target=\(sshOptions.displayDestination) relayPort=\(sshOptions.remoteRelayPort) " +
            "workspace=\(String(workspaceId.prefix(8))) stage=workspace.create elapsedMs=\(Int(Date().timeIntervalSince(workspaceCreateStartedAt) * 1000))"
        )
        let configuredPayload: [String: Any]
        do {
            if let workspaceName = sshOptions.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceName.isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": workspaceName,
                ])
            }

            var configureParams: [String: Any] = [
                "workspace_id": workspaceId,
                "destination": sshOptions.displayDestination,
                "auto_connect": deferredRemoteReconnectCommandScript == nil,
            ]
            if let configuredForegroundAuthToken {
                configureParams["foreground_auth_token"] = configuredForegroundAuthToken
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
            configureParams["terminal_startup_command"] = reusableTerminalStartupCommand
            if sshOptions.skipDaemonBootstrap {
                configureParams["skip_daemon_bootstrap"] = true
            }
            if let persistentDaemonSlot {
                configureParams["preserve_after_terminal_exit"] = true
                configureParams["persistent_daemon_slot"] = persistentDaemonSlot
            }

            cliDebugLog(
                "cli.ssh.remote.configure workspace=\(String(workspaceId.prefix(8))) " +
                "target=\(sshOptions.displayDestination) relayPort=\(sshOptions.remoteRelayPort) " +
                "controlPath=\(sshOptionValue(named: "ControlPath", in: remoteSSHOptions) ?? "nil") " +
                "deferredReconnect=\(deferredRemoteReconnectCommandScript == nil ? 0 : 1) " +
                "sshOptions=\(remoteSSHOptions.joined(separator: "|"))"
            )
            let configureStartedAt = Date()
            configuredPayload = try client.sendV2(method: "workspace.remote.configure", params: configureParams)
            var selectParams: [String: Any] = ["workspace_id": workspaceId]
            if let workspaceWindowId, !workspaceWindowId.isEmpty {
                selectParams["window_id"] = workspaceWindowId
            }
            // `cmux ssh` is an explicit "open this remote workspace now" action,
            // so we intentionally select the newly created workspace after wiring
            // up the remote connection — unless --no-focus is passed.
            if !sshOptions.noFocus {
                let selectStartedAt = Date()
                _ = try client.sendV2(method: "workspace.select", params: selectParams)
                cliDebugLog(
                    "cli.ssh.timing target=\(sshOptions.displayDestination) relayPort=\(sshOptions.remoteRelayPort) " +
                    "workspace=\(String(workspaceId.prefix(8))) stage=workspace.select elapsedMs=\(Int(Date().timeIntervalSince(selectStartedAt) * 1000))"
                )
            }
            let remoteState = ((configuredPayload["remote"] as? [String: Any])?["state"] as? String) ?? "unknown"
            cliDebugLog(
                "cli.ssh.remote.configure.ok workspace=\(String(workspaceId.prefix(8))) state=\(remoteState)"
            )
            cliDebugLog(
                "cli.ssh.timing target=\(sshOptions.displayDestination) relayPort=\(sshOptions.remoteRelayPort) " +
                "workspace=\(String(workspaceId.prefix(8))) stage=workspace.remote.configure elapsedMs=\(Int(Date().timeIntervalSince(configureStartedAt) * 1000))"
            )
        } catch {
            cliDebugLog(
                "cli.ssh.remote.configure.error workspace=\(String(workspaceId.prefix(8))) error=\(String(describing: error))"
            )
            do {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            } catch {
                let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            throw error
        }

        var payload = configuredPayload

        let redactsDestination = sshOptions.destination != sshOptions.displayDestination
        if redactsDestination {
            payload["ssh_command"] = "<redacted>"
            payload["ssh_terminal_command"] = "<redacted>"
            payload["ssh_startup_command"] = "<redacted>"
            payload["ssh_terminal_startup_command"] = "<redacted>"
        } else {
            payload["ssh_command"] = initialSSHCommand
            payload["ssh_terminal_command"] = remoteTerminalSSHCommand
            payload["ssh_startup_command"] = initialSSHStartupCommand
            payload["ssh_terminal_startup_command"] = reusableTerminalStartupCommand
        }
        payload["ssh_env_overrides"] = [
            "GHOSTTY_SHELL_FEATURES": shellFeaturesValue,
        ]
        payload["remote_relay_port"] = sshOptions.remoteRelayPort
        if usesPersistentSSHPTY, let workspaceInitialSurfaceId {
            payload["ssh_pty_session_id"] = "ssh-\(workspaceId)-\(workspaceInitialSurfaceId)"
        }
        if let persistentDaemonSlot {
            payload["persistent_daemon_slot"] = persistentDaemonSlot
        }
        logSSHTiming("complete", extra: "workspace=\(String(workspaceId.prefix(8)))")
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId
            let remote = payload["remote"] as? [String: Any]
            let state = (remote?["state"] as? String) ?? "unknown"
            print("OK workspace=\(workspaceHandle) target=\(sshOptions.displayDestination) state=\(state)")
        }
    }

    private func parseSSHCommandOptions(
        _ commandArgs: [String],
        localSocketPath: String = "",
        remoteRelayPort: Int = 0,
        windowOverride: String? = nil
    ) throws -> SSHCommandOptions {
        var destination: String?
        var port: Int?
        var identityFile: String?
        var workspaceName: String?
        var windowRaw: String?
        var noFocus = false
        var sshOptions: [String] = []
        var extraArguments: [String] = []
        var forwardAgentOverride: Bool?

        var passthrough = false
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if passthrough {
                extraArguments.append(arg)
                index += 1
                continue
            }

            switch arg {
            case "--":
                passthrough = true
                index += 1
            case "--port":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --port requires a value")
                }
                guard let parsed = Int(commandArgs[index + 1]), parsed > 0, parsed <= 65535 else {
                    throw CLIError(message: "ssh: --port must be 1-65535")
                }
                port = parsed
                index += 2
            case "--identity":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --identity requires a path")
                }
                identityFile = commandArgs[index + 1]
                index += 2
            case "--name":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --name requires a workspace title")
                }
                workspaceName = commandArgs[index + 1]
                index += 2
            case "--window":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --window requires a window id")
                }
                windowRaw = commandArgs[index + 1]
                index += 2
            case "--no-focus":
                noFocus = true
                index += 1
            case "-A", "--forward-agent":
                forwardAgentOverride = true
                index += 1
            case "-a", "--no-forward-agent":
                forwardAgentOverride = false
                index += 1
            case "--ssh-option":
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "ssh: --ssh-option requires a value")
                }
                let value = commandArgs[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    sshOptions.append(value)
                }
                index += 2
            default:
                if arg.hasPrefix("--") {
                    throw CLIError(message: "ssh: unknown flag '\(arg)'")
                }
                if destination == nil {
                    if arg.hasPrefix("-") {
                        throw CLIError(
                            message: "ssh: destination must be <user@host>. Use --port/--identity/--ssh-option for SSH flags and `--` for remote command args."
                        )
                    }
                    destination = arg
                } else {
                    extraArguments.append(arg)
                }
                index += 1
            }
        }

        guard let destination else {
            throw CLIError(message: "ssh requires a destination (example: cmux ssh user@host)")
        }
        let agentForwarding = resolvedSSHAgentForwarding(
            sshOptions: sshOptions,
            override: forwardAgentOverride
        )
        return SSHCommandOptions(
            destination: destination,
            port: port,
            identityFile: identityFile,
            workspaceName: workspaceName,
            windowRaw: windowRaw ?? windowOverride,
            noFocus: noFocus,
            sshOptions: agentForwarding.sshOptions,
            extraArguments: extraArguments,
            agentSocketPath: agentForwarding.agentSocketPath,
            localSocketPath: localSocketPath,
            remoteRelayPort: remoteRelayPort
        )
    }

    func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        SSHAgentSocketResolver().hasOptionKey(options, key: key)
    }

    private func deferredRemoteReconnectLocalCommandScript(
        in options: [String],
        localCLIPath: String?,
        foregroundAuthToken: String
    ) -> String? {
        guard shouldDeferRemoteReconnect(in: options) else { return nil }
        let preferredCLIPath = localCLIPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedForegroundAuthToken = shellQuote(foregroundAuthToken)
        return [
            preferredCLIPath.map { "cmux_reconnect_cli=\(shellQuote($0));" } ?? "cmux_reconnect_cli=\"\";",
            "cmux_reconnect_socket=\"${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}\";",
            "if [ -z \"$cmux_reconnect_cli\" ] && [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]; then cmux_reconnect_cli=\"$CMUX_BUNDLED_CLI_PATH\"; fi;",
            "if [ ! -x \"$cmux_reconnect_cli\" ]; then cmux_reconnect_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi;",
            "if [ -n \"${CMUX_WORKSPACE_ID:-}\" ]; then",
            "if [ -z \"$cmux_reconnect_socket\" ]; then printf '%s\\n' 'cmux: deferred SSH reconnect skipped, local cmux socket not found' >&2;",
            "elif [ -z \"$cmux_reconnect_cli\" ] || [ ! -x \"$cmux_reconnect_cli\" ]; then printf '%s\\n' 'cmux: deferred SSH reconnect skipped, local cmux CLI not found' >&2;",
            "else",
            "cmux_reconnect_token=\(quotedForegroundAuthToken);",
            "cmux_reconnect_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"$cmux_reconnect_token\\\"}\";",
            "\"$cmux_reconnect_cli\" --socket \"$cmux_reconnect_socket\" rpc workspace.remote.foreground_auth_ready \"$cmux_reconnect_payload\" >/dev/null 2>&1 || true;",
            "unset cmux_reconnect_payload cmux_reconnect_token;",
            "fi;",
            "fi;",
            "unset cmux_reconnect_socket cmux_reconnect_cli;",
        ].joined(separator: " ")
    }

    private func sshConnectionTimingLocalCommandScript(target: String, relayPort: Int) -> String {
        let escapedTarget = target
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            "cmux_ssh_log_path=\"\";",
            "if [ -r /tmp/cmux-last-debug-log-path ]; then cmux_ssh_log_path=\"$(tr -d '\\r\\n' < /tmp/cmux-last-debug-log-path 2>/dev/null || true)\"; fi;",
            "if [ -n \"$cmux_ssh_log_path\" ]; then",
            "cmux_ssh_ts=\"$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec=\"milliseconds\").replace(\"+00:00\", \"Z\"))' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)\";",
            "printf '%s [cmux-cli] cli.ssh.handshake target=\(escapedTarget) relayPort=\(relayPort) stage=ssh.connected workspace=%s surface=%s\\n' \"$cmux_ssh_ts\" \"${CMUX_WORKSPACE_ID:-nil}\" \"${CMUX_SURFACE_ID:-nil}\" >> \"$cmux_ssh_log_path\";",
            "fi;",
            "unset cmux_ssh_log_path cmux_ssh_ts;",
        ].joined(separator: " ")
    }

    private func shouldDeferRemoteReconnect(in options: [String]) -> Bool {
        sshOptionsSupportReusableForegroundAuth(options)
    }

    internal func sshOptionsSupportReusableForegroundAuth(_ options: [String]) -> Bool {
        guard !hasSSHOptionKey(options, key: "LocalCommand"),
              !hasSSHOptionKey(options, key: "PermitLocalCommand") else {
            return false
        }

        guard let controlPath = sshOptionValue(named: "ControlPath", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return false
        }

        let controlMaster = sshOptionValue(named: "ControlMaster", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sshOptionValueIsDisabled(controlMaster) {
            return false
        }

        let controlPersist = sshOptionValue(named: "ControlPersist", in: options)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !sshOptionValueIsDisabled(controlPersist, zeroIsDisabled: false)
    }

    private func sshOptionValueIsDisabled(_ rawValue: String?, zeroIsDisabled: Bool = true) -> Bool {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized else { return false }
        return ["no", "false", "off"].contains(normalized) || (zeroIsDisabled && normalized == "0")
    }

    func defaultSSHControlPathTemplate(remoteRelayPort: Int? = nil) -> String {
        if let remoteRelayPort, remoteRelayPort > 0 {
            return "/tmp/cmux-ssh-\(getuid())-\(remoteRelayPort)-%C"
        }
        return "/tmp/cmux-ssh-\(getuid())-%C"
    }

    func normalizedSSHIdentityPath(_ rawPath: String?) -> String? {
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

    func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func execInteractiveProgram(
        launchPath: String,
        arguments: [String]
    ) throws -> Never {
        var argv = ([launchPath] + arguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        if launchPath.contains("/") {
            execv(launchPath, &argv)
        } else {
            execvp(launchPath, &argv)
        }
        let code = errno
        throw CLIError(message: "Failed to launch \(launchPath): \(String(cString: strerror(code)))")
    }

    func sshOptionValue(named key: String, in options: [String]) -> String? {
        SSHAgentSocketResolver().optionValue(named: key, in: options)
    }

    func cliDebugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        let trimmedExplicit = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String? = {
            if let trimmedExplicit, !trimmedExplicit.isEmpty {
                return trimmedExplicit
            }
            guard let marker = try? String(contentsOfFile: "/tmp/cmux-last-debug-log-path", encoding: .utf8) else {
                return nil
            }
            let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedMarker.isEmpty ? nil : trimmedMarker
        }()
        guard let path else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [cmux-cli] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
#endif
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
        let result = CLIProcessRunner.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            stdinText: stdinText,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }

}
