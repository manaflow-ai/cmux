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


// MARK: - SSH bootstrap command building
extension CMUXCLI {
    func resolvedSSHAgentForwarding(
        sshOptions: [String],
        override: Bool?
    ) -> (sshOptions: [String], agentSocketPath: String?) {
        let forwardAgentValue: String?
        var resolvedOptions = sshOptions

        if let override {
            resolvedOptions = sshOptionsRemovingForwardAgent(resolvedOptions)
            resolvedOptions.append("ForwardAgent=\(override ? "yes" : "no")")
            forwardAgentValue = override ? "yes" : nil
        } else if let explicitForwardAgent = sshForwardAgentValue(in: resolvedOptions) {
            forwardAgentValue = explicitForwardAgent
        } else {
            forwardAgentValue = nil
        }

        let resolver = SSHAgentSocketResolver()
        let explicitAgentSocketPath = forwardAgentValue
            .flatMap(resolver.agentSocketPath(forForwardAgentValue:))
            .flatMap(existingSSHAgentSocketPath)
        let agentSocketPath = explicitAgentSocketPath
            ?? existingSSHAgentSocketPath(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
        return (resolvedOptions, agentSocketPath)
    }

    private func sshOptionsRemovingForwardAgent(_ options: [String]) -> [String] {
        SSHAgentSocketResolver().removingOptions(named: "ForwardAgent", from: options)
    }

    private func sshForwardAgentValue(in options: [String]) -> String? {
        SSHAgentSocketResolver().optionValue(named: "ForwardAgent", in: options)
    }

    /// Returns a normalized agent socket path only when it currently exists.
    private func existingSSHAgentSocketPath(_ value: String?) -> String? {
        guard let path = SSHAgentSocketResolver().normalizedAgentSocketPath(value),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    func buildSSHCommandText(
        _ options: SSHCommandOptions,
        remoteBootstrapScript: String? = nil,
        localCommandScript: String? = nil
    ) -> String {
        buildSSHCommandArguments(
            options,
            remoteBootstrapScript: remoteBootstrapScript,
            localCommandScript: localCommandScript
        )
        .map(shellQuote)
        .joined(separator: " ")
    }

    func buildSSHCommandArguments(
        _ options: SSHCommandOptions,
        remoteBootstrapScript: String? = nil,
        localCommandScript: String? = nil
    ) -> [String] {
        var parts = baseSSHArguments(options, localCommandScript: localCommandScript)
        let trimmedRemoteBootstrap = remoteBootstrapScript?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if options.extraArguments.isEmpty {
            if let trimmedRemoteBootstrap, !trimmedRemoteBootstrap.isEmpty {
                let remoteCommand = openSSHRemoteCommandValue(
                    shellScript: encodedRemoteBootstrapCommand(
                        trimmedRemoteBootstrap,
                        remoteRelayPort: options.remoteRelayPort
                    )
                )
                parts += ["-o", "RemoteCommand=\(remoteCommand)"]
            }
            if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
                parts.append("-tt")
            }
            parts.append(options.destination)
        } else {
            parts.append(options.destination)
            parts.append(contentsOf: options.extraArguments)
        }
        return parts
    }

    func buildBootstrapSSHStartupCommand(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        localCommandScript: String? = nil,
        controlPathPreflightShellFunction: String? = nil
    ) throws -> String {
        let commandSnippet = buildSSHBootstrapCommandSnippet(
            options: options,
            remoteBootstrapScript: remoteBootstrapScript,
            localCommandScript: localCommandScript
        )
        return try buildSSHStartupCommand(
            sshCommand: commandSnippet,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: true,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction
        )
    }

    func buildReusableBootstrapSSHStartupCommand(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        localCommandScript: String? = nil,
        controlPathPreflightShellFunction: String? = nil
    ) -> String {
        let commandSnippet = buildSSHBootstrapCommandSnippet(
            options: options,
            remoteBootstrapScript: remoteBootstrapScript,
            localCommandScript: localCommandScript
        )
        return buildReusableSSHStartupCommand(
            sshCommand: commandSnippet,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: true,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction
        )
    }

    private func buildSSHBootstrapCommandSnippet(
        options: SSHCommandOptions,
        remoteBootstrapScript: String,
        localCommandScript: String? = nil
    ) -> String {
        let encodedBootstrapScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let installSSHPrefix = baseSSHArguments(options, localCommandScript: localCommandScript).map(shellQuote).joined(separator: " ")
        let sessionSSHPrefix = baseSSHArguments(options).map(shellQuote).joined(separator: " ")
        let remoteCommandTemplate = openSSHRemoteCommandValue(
            shellScript: stagedRemoteBootstrapCommandShell(
                remoteRelayPort: options.remoteRelayPort
            )
        )
        let remoteBootstrapInstallCommand = posixShellCommand(
            remoteBootstrapInstallShell(remoteRelayPort: options.remoteRelayPort)
        )
        var lines: [String] = [
            "cmux_workspace_id=\"${CMUX_WORKSPACE_ID:-}\"",
            "cmux_surface_id=\"${CMUX_SURFACE_ID:-}\"",
            "cmux_remote_bootstrap_b64=\(shellQuote(encodedBootstrapScript))",
            "cmux_remote_bootstrap=\"$(printf %s \"$cmux_remote_bootstrap_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_remote_bootstrap_b64\" | base64 -D 2>/dev/null)\"",
            "cmux_remote_bootstrap=\"$(printf '%s' \"$cmux_remote_bootstrap\" | sed \"s/__CMUX_WORKSPACE_ID__/$cmux_workspace_id/g; s/__CMUX_SURFACE_ID__/$cmux_surface_id/g\")\"",
            "printf '%s' \"$cmux_remote_bootstrap\" | command \(installSSHPrefix) -T \(shellQuote(options.destination)) \(shellQuote(remoteBootstrapInstallCommand))",
            "cmux_remote_install_status=$?",
            "if [ \"$cmux_remote_install_status\" -ne 0 ]; then",
            "  exit \"$cmux_remote_install_status\"",
            "fi",
            "cmux_remote_command_template=\(shellQuote(remoteCommandTemplate))",
            "cmux_remote_command=\"$(printf '%s' \"$cmux_remote_command_template\" | sed \"s/__CMUX_WORKSPACE_ID__/$cmux_workspace_id/g; s/__CMUX_SURFACE_ID__/$cmux_surface_id/g\")\"",
        ]

        var sshInvocation = "command \(sessionSSHPrefix) -o \"RemoteCommand=$cmux_remote_command\""
        if !hasSSHOptionKey(options.sshOptions, key: "RequestTTY") {
            sshInvocation += " -tt"
        }
        sshInvocation += " " + shellQuote(options.destination)
        lines.append(sshInvocation)
        return lines.joined(separator: "\n")
    }

    private func stagedRemoteBootstrapCommandShell(
        remoteRelayPort: Int
    ) -> String {
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: true)
        lines.append("/bin/sh \"$HOME/.cmux/relay/\(remoteRelayPort).bootstrap.sh\"")
        return lines.joined(separator: "\n")
    }

    private func remoteBootstrapInstallShell(remoteRelayPort: Int) -> String {
        [
            "set -eu",
            "umask 077",
            "cmux_bootstrap_path=\"$HOME/.cmux/relay/\(remoteRelayPort).bootstrap.sh\"",
            "mkdir -p \"$HOME/.cmux/relay\"",
            "cat > \"$cmux_bootstrap_path\"",
            "chmod 700 \"$cmux_bootstrap_path\" >/dev/null 2>&1 || true",
        ].joined(separator: "\n")
    }

    private func runtimeEncodedRemoteBootstrapCommandShell(
        base64Placeholder: String,
        remoteRelayPort: Int
    ) -> String {
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: false)
        lines += [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s '\(base64Placeholder)' | base64 -d 2>/dev/null || printf %s '\(base64Placeholder)' | base64 -D 2>/dev/null) > \"$cmux_tmp\" || { rm -f \"$cmux_tmp\"; exit 1; }",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "rm -f \"$cmux_tmp\"",
            "exit $cmux_status",
        ]
        return lines.joined(separator: "\n")
    }

    func remoteBootstrapTTYCaptureLines(
        remoteRelayPort: Int,
        includeRelayRPC: Bool
    ) -> [String] {
        guard remoteRelayPort > 0 else { return [] }

        var lines: [String] = [
            "cmux_bootstrap_tty=\"$(tty 2>/dev/null || true)\"",
            "cmux_bootstrap_tty=\"${cmux_bootstrap_tty##*/}\"",
            "if [ -n \"$cmux_bootstrap_tty\" ] && [ \"$cmux_bootstrap_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.cmux/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$cmux_bootstrap_tty\" > \"$HOME/.cmux/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "  export CMUX_BOOTSTRAP_TTY=\"$cmux_bootstrap_tty\"",
        ]

        if includeRelayRPC {
            lines += [
                "  cmux_relay_cli=\"$HOME/.cmux/bin/cmux\"",
                "  if [ ! -x \"$cmux_relay_cli\" ]; then cmux_relay_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
                "  if [ -n \"$cmux_relay_cli\" ]; then",
                "    cmux_relay_report_tty='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"tty_name\":\"'$cmux_bootstrap_tty'\"}'",
                "    cmux_relay_ports_kick='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"reason\":\"command\"}'",
                "    if [ -n \"__CMUX_SURFACE_ID__\" ]; then",
                "      cmux_relay_report_tty='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"surface_id\":\"__CMUX_SURFACE_ID__\",\"tty_name\":\"'$cmux_bootstrap_tty'\"}'",
                "      cmux_relay_ports_kick='{\"workspace_id\":\"__CMUX_WORKSPACE_ID__\",\"surface_id\":\"__CMUX_SURFACE_ID__\",\"reason\":\"command\"}'",
                "    fi",
                "    env -u CMUX_SOCKET CMUX_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" \"$cmux_relay_cli\" rpc surface.report_tty \"$cmux_relay_report_tty\" >/dev/null 2>&1 || true",
                "    env -u CMUX_SOCKET CMUX_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" \"$cmux_relay_cli\" rpc surface.ports_kick \"$cmux_relay_ports_kick\" >/dev/null 2>&1 || true",
                "    unset cmux_relay_cli cmux_relay_report_tty cmux_relay_ports_kick",
                "  fi",
            ]
        }

        lines.append("fi")
        return lines
    }

    func effectiveSSHOptions(_ options: [String], remoteRelayPort: Int? = nil) -> [String] {
        var merged = sshOptionsWithControlSocketDefaults(options, remoteRelayPort: remoteRelayPort)
        if !hasSSHOptionKey(merged, key: "StrictHostKeyChecking") {
            merged.append("StrictHostKeyChecking=accept-new")
        }
        return merged
    }

    func sshControlPathPreflightShellFunction(options: SSHCommandOptions) -> String? {
        let effectiveOptions = effectiveSSHOptions(
            options.sshOptions,
            remoteRelayPort: options.remoteRelayPort
        )
        guard let controlMaster = sshOptionValue(named: "ControlMaster", in: effectiveOptions)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !["no", "false", "off"].contains(controlMaster),
              let controlPath = sshOptionValue(named: "ControlPath", in: effectiveOptions)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        let sshPrefix = baseSSHArguments(options).map(shellQuote).joined(separator: " ")
        let destination = shellQuote(options.destination)
        return [
            "cmux_ssh_preflight_control_path() {",
            #"  cmux_ssh_control_path="$(command \#(sshPrefix) -G \#(destination) 2>/dev/null | awk 'tolower($1) == "controlpath" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }')" "#,
            "  case \"${cmux_ssh_control_path:-}\" in",
            "    /tmp/cmux-ssh-*|\"$HOME\"/.cmux/control/*)",
            "      if ! command \(sshPrefix) -S \"$cmux_ssh_control_path\" -O check \(destination) >/dev/null 2>&1; then",
            "        rm -f -- \"$cmux_ssh_control_path\" 2>/dev/null || true",
            "      fi",
            "      ;;",
            "  esac",
            "  unset cmux_ssh_control_path",
            "}",
        ].joined(separator: "\n")
    }

    func buildInteractiveRemoteShellScript(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let remoteTerminalLines = interactiveRemoteTerminalSetupLines(terminfoSource: terminfoSource)
        let remoteLocaleLines = RemoteShellEnvironment.utf8LocaleSetupLines()
        let remoteEnvExportLines = interactiveRemoteShellExportLines(shellFeatures: shellFeatures)
        let shellStateDir = shellStateDirForRemoteRelayPort(remoteRelayPort)
        let remoteCallerExportLines = [
            "if [ -n '__CMUX_WORKSPACE_ID__' ]; then export CMUX_WORKSPACE_ID='__CMUX_WORKSPACE_ID__'; fi",
            "if [ -n '__CMUX_WORKSPACE_ID__' ]; then export CMUX_TAB_ID='__CMUX_WORKSPACE_ID__'; fi",
            "if [ -n '__CMUX_SURFACE_ID__' ]; then export CMUX_SURFACE_ID='__CMUX_SURFACE_ID__'; export CMUX_PANEL_ID='__CMUX_SURFACE_ID__'; fi",
        ]
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        var commonShellExportLines = remoteTerminalLines
        commonShellExportLines.append(contentsOf: remoteLocaleLines)
        commonShellExportLines.append(contentsOf: remoteEnvExportLines)
        commonShellExportLines.append("export PATH=\"$HOME/.cmux/bin:$PATH\"")
        commonShellExportLines.append("export CMUX_BUNDLED_CLI_PATH=\"$HOME/.cmux/bin/cmux\"")
        commonShellExportLines.append("export CMUX_SHELL_INTEGRATION_DIR=\"\(shellStateDir)\"")
        if let relaySocket {
            commonShellExportLines.append("export CMUX_SOCKET_PATH=\(relaySocket)")
        }
        commonShellExportLines.append(contentsOf: remoteCallerExportLines)
        commonShellExportLines.append(contentsOf: [
            "hash -r >/dev/null 2>&1 || true",
            "rehash >/dev/null 2>&1 || true",
        ])
        var zshShellLines = commonShellExportLines
        zshShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh"; fi"#
        )
        var bashShellLines = commonShellExportLines
        bashShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash"; fi"#
        )
        let zshBootstrap = RemoteRelayZshBootstrap(shellStateDir: shellStateDir)
        let zshEnvLines = zshBootstrap.zshEnvLines
        let zshProfileLines = zshBootstrap.zshProfileLines
        let zshRCLines = zshBootstrap.zshRCLines(commonShellLines: zshShellLines)
        let zshLoginLines = zshBootstrap.zshLoginLines
        let bundledZshIntegration = bundledShellIntegrationScript(named: "cmux-zsh-integration.zsh")
        let bundledBashIntegration = bundledShellIntegrationScript(named: "cmux-bash-integration.bash")
        let bashRCLines = [
            "if [ -f \"$HOME/.bash_profile\" ]; then . \"$HOME/.bash_profile\"; elif [ -f \"$HOME/.bash_login\" ]; then . \"$HOME/.bash_login\"; elif [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + bashShellLines
        let relayWarmupLines = interactiveRemoteRelayWarmupLines(remoteRelayPort: remoteRelayPort)

        var outerLines: [String] = [
            "mkdir -p \"$HOME/.cmux/relay\"",
            "cmux_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$cmux_shell_dir\"",
        ]
        if let bundledZshIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/cmux-zsh-integration.zsh\" <<'CMUXCMUXZSH'",
                bundledZshIntegration,
                "CMUXCMUXZSH",
            ]
        }
        if let bundledBashIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/cmux-bash-integration.bash\" <<'CMUXCMUXBASH'",
                bundledBashIntegration,
                "CMUXCMUXBASH",
            ]
        }
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines += [
            "CMUX_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cat > \"$cmux_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$cmux_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$cmux_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshRCLines)
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$cmux_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshLoginLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$cmux_shell_dir/.zshenv\" \"$cmux_shell_dir/.zprofile\" \"$cmux_shell_dir/.zshrc\" \"$cmux_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export CMUX_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$cmux_shell_dir\"",
            "    exec \"$CMUX_LOGIN_SHELL\" -il",
            "    ;;",
            "  bash)",
            "    cat > \"$cmux_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: bashRCLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$cmux_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    exec \"$CMUX_LOGIN_SHELL\" --rcfile \"$cmux_shell_dir/.bashrc\" -i",
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines += [
            "exec \"$CMUX_LOGIN_SHELL\" -i",
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

}
