internal import Foundation

/// Builds an Eternal Terminal (`et`) terminal command with explicit SSH fallback.
///
/// The builder receives complete SSH argument prefixes from the caller so the
/// `etterminal` probe and bootstrap staging honor the same host alias,
/// identity, port, and OpenSSH options as the workspace control connection.
/// ET bootstraps its own session over SSH, so the same management options
/// reach `et` through `--ssh-option`.
public struct EternalTerminalCommandBuilder: Sendable {
    private let capabilityProbeSSHArguments: [String]
    private let sessionSSHOptions: [String]
    private let destination: String
    private let options: EternalTerminalOptions
    private let forwardsSSHAgent: Bool
    private let sshAgentSocketPath: String?
    private let remoteCommandArguments: [String]
    private let remoteRelayPort: Int?
    private let preparationShellScript: String?
    private let managementReadyShellScript: String?
    private let sshFallbackCommand: String
    private let sshFallbackLauncherPaths: [String]
    private let messages: Messages

    /// User-facing explanations printed before the terminal continues over SSH.
    public struct Messages: Sendable {
        /// Printed when no local `et` executable exists.
        public let localMissing: String
        /// Printed when `etterminal` is absent on the remote host.
        public let remoteMissing: String
        /// Printed when the remote `etterminal` probe cannot complete.
        public let remoteProbeFailed: String
        /// Printed when the remote `etserver` port does not accept connections.
        public let serverUnreachable: String
        /// Printed when bootstrap staging fails.
        public let remoteBootstrapInstallFailed: String
        /// Warns that an explicit SSH retry may run the remote command again.
        public let startupRecoveryPrompt: String

        /// Creates the fallback explanations.
        ///
        /// - Parameters:
        ///   - localMissing: No local `et` executable exists.
        ///   - remoteMissing: The remote host has no `etterminal`.
        ///   - remoteProbeFailed: The remote `etterminal` probe failed.
        ///   - serverUnreachable: The remote `etserver` port refused or timed out.
        ///   - remoteBootstrapInstallFailed: Bootstrap staging failed.
        ///   - startupRecoveryPrompt: Interactive recovery warning after an ET error.
        public init(
            localMissing: String,
            remoteMissing: String,
            remoteProbeFailed: String,
            serverUnreachable: String,
            remoteBootstrapInstallFailed: String,
            startupRecoveryPrompt: String
        ) {
            self.localMissing = localMissing
            self.remoteMissing = remoteMissing
            self.remoteProbeFailed = remoteProbeFailed
            self.serverUnreachable = serverUnreachable
            self.remoteBootstrapInstallFailed = remoteBootstrapInstallFailed
            self.startupRecoveryPrompt = startupRecoveryPrompt
        }
    }

    /// Creates an Eternal Terminal command builder.
    ///
    /// - Parameters:
    ///   - capabilityProbeSSHArguments: SSH executable and options used to check for `etterminal`
    ///     and to resolve the destination's host name.
    ///   - sessionSSHOptions: OpenSSH `-o` values passed to `et --ssh-option` for its bootstrap.
    ///   - destination: SSH destination or host alias.
    ///   - options: ET port, terminal path, and tunnels.
    ///   - forwardsSSHAgent: Whether to pass `--forward-ssh-agent`.
    ///   - sshAgentSocketPath: Local agent socket forwarded with `--ssh-socket`.
    ///   - remoteCommandArguments: Optional command argv the remote shell replaces itself with.
    ///   - remoteRelayPort: Optional remote relay whose presence enables lifecycle attempt registration.
    ///   - preparationShellScript: Optional local preparation run before capability checks.
    ///   - managementReadyShellScript: Optional local callback run after preparation and before ET starts.
    ///   - sshFallbackCommand: Complete local SSH terminal command used when ET is unavailable.
    ///   - sshFallbackLauncherPaths: Launcher files that only `sshFallbackCommand` runs; retained until ET finishes or SSH takes ownership.
    ///   - messages: Fallback explanations.
    public init(
        capabilityProbeSSHArguments: [String],
        sessionSSHOptions: [String],
        destination: String,
        options: EternalTerminalOptions = .default,
        forwardsSSHAgent: Bool = false,
        sshAgentSocketPath: String? = nil,
        remoteCommandArguments: [String],
        remoteRelayPort: Int? = nil,
        preparationShellScript: String? = nil,
        managementReadyShellScript: String? = nil,
        sshFallbackCommand: String,
        sshFallbackLauncherPaths: [String] = [],
        messages: Messages
    ) {
        self.capabilityProbeSSHArguments = capabilityProbeSSHArguments
        self.sessionSSHOptions = sessionSSHOptions
        self.destination = destination
        self.options = options
        self.forwardsSSHAgent = forwardsSSHAgent
        self.sshAgentSocketPath = sshAgentSocketPath
        self.remoteCommandArguments = remoteCommandArguments
        self.remoteRelayPort = remoteRelayPort
        self.preparationShellScript = preparationShellScript
        self.managementReadyShellScript = managementReadyShellScript
        self.sshFallbackCommand = sshFallbackCommand
        self.sshFallbackLauncherPaths = sshFallbackLauncherPaths
        self.messages = messages
    }

    /// OpenSSH `-o` values for ET's bootstrap `ssh`, taken from the
    /// management lane's `ssh` argv so ET authenticates the same way.
    ///
    /// `-p` and `-i` become `Port=` and `IdentityFile=`. ET runs its
    /// bootstrap non-interactively, so `RequestTTY` values are dropped.
    ///
    /// - Parameter sshArguments: An `ssh` argv beginning with the executable.
    /// - Returns: Values for repeated `et --ssh-option`.
    public static func sessionSSHOptions(fromSSHArguments sshArguments: [String]) -> [String] {
        var options: [String] = []
        var index = sshArguments.index(after: sshArguments.startIndex)
        while index < sshArguments.endIndex {
            let argument = sshArguments[index]
            let value = sshArguments.index(after: index) < sshArguments.endIndex
                ? sshArguments[sshArguments.index(after: index)]
                : nil
            switch (argument, value) {
            case ("-o", let value?):
                options.append(value)
                index += 2
            case ("-p", let value?):
                options.append("Port=\(value)")
                index += 2
            case ("-i", let value?):
                // `-o` values parse like ssh_config lines, so a path with
                // spaces needs config quoting to stay one argument.
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let quoted = "\"\(escaped)\""
                options.append("IdentityFile=\(quoted)")
                index += 2
            default:
                index += 1
            }
        }
        return SSHAgentSocketResolver().removingOptions(named: "RequestTTY", from: options)
    }

    /// Whether the effective `ForwardAgent` option asks to forward the agent.
    ///
    /// - Parameter sshOptions: OpenSSH-style `Key=Value` options.
    /// - Returns: `true` for a yes-like value or an agent socket path.
    public static func forwardsSSHAgent(sshOptions: [String]) -> Bool {
        let resolver = SSHAgentSocketResolver()
        guard let value = resolver.optionValue(named: "ForwardAgent", in: sshOptions) else { return false }
        return resolver.agentSocketPath(forForwardAgentValue: value) != nil
    }

    /// The command ET types into the remote login shell, or `nil` for a plain shell.
    ///
    /// ET has no remote argv: `--command` is injected into the user's login
    /// shell. `exec` replaces that shell (fish and csh accept the same form),
    /// so the remote program runs exactly as SSH or Mosh would run it.
    var remoteShellCommand: String? {
        guard !remoteCommandArguments.isEmpty else { return nil }
        return "exec " + remoteCommandArguments.map(\.remoteCommandShellQuoted).joined(separator: " ")
    }

    /// The `et` argv after the executable, with the configured terminal path.
    public var clientArguments: [String] {
        clientArguments(terminalPathArguments: options.terminalPath.map { ["--terminal-path", $0] } ?? [])
    }

    private func clientArguments(terminalPathArguments: [String]) -> [String] {
        var arguments = terminalPathArguments + options.clientArguments(includingTerminalPath: false)
        if forwardsSSHAgent {
            arguments.append("--forward-ssh-agent")
            if let sshAgentSocketPath {
                arguments += ["--ssh-socket", sshAgentSocketPath]
            }
        }
        for sshOption in sessionSSHOptions {
            arguments += ["--ssh-option", sshOption]
        }
        if let remoteShellCommand {
            // `--noexit` keeps ET from appending `; exit`; if the exec fails,
            // the user keeps the login shell instead of losing the pane.
            arguments += ["--command", remoteShellCommand, "--noexit"]
        }
        arguments.append(destination)
        return arguments
    }

    /// Returns a shell command that launches ET or falls back to SSH.
    ///
    /// Capability detection happens before ET starts: the local executable is
    /// resolved from `PATH`, the remote host is checked for `etterminal`
    /// through the SSH management lane (exit 127 means missing), and the
    /// `etserver` port on the SSH-resolved host name must accept a TCP
    /// connection. Each failure prints its reason and continues over SSH.
    /// The probed `etterminal` path is passed to ET as `--terminal-path`,
    /// because ET's own SSH hop only searches the non-interactive `PATH`.
    ///
    /// - Returns: A complete `/bin/sh -c` terminal startup command.
    public func command() -> String {
        let resolver = SSHAgentSocketResolver()
        // ET resolves its TCP route and enables agent forwarding from its own
        // SSH config parser, independently of --ssh-option. Preserve explicit
        // cmux overrides through SSH when ET cannot honor their semantics.
        let overridesRoute = ["HostName", "ProxyJump", "ProxyCommand"].contains {
            resolver.optionValue(named: $0, in: sessionSSHOptions) != nil
        }
        let disablesAgent = resolver.optionValue(named: "ForwardAgent", in: sessionSSHOptions)
            .map { resolver.agentSocketPath(forForwardAgentValue: $0) == nil } ?? false
        if overridesRoute || disablesAgent {
            let script = "printf '%s\\n' \(messages.remoteProbeFailed.remoteCommandShellQuoted) >&2; exec /bin/sh -c \(sshFallbackCommand.remoteCommandShellQuoted)"
            return "/bin/sh -c \(script.remoteCommandShellQuoted)"
        }
        let localResolver = RemoteExecutableCommandBuilder(
            executableName: "et",
            notFoundSentinel: "cmux-et: local et not found"
        )
        let remoteCapabilityCommand: String
        if let terminalPath = options.terminalPath {
            let script = "if [ -x \"$1\" ]; then printf '%s\\n' \"$1\"; exit 0; fi; printf '%s\\n' 'cmux-et: remote etterminal not found' >&2; exit 127"
            remoteCapabilityCommand = "/bin/sh -c \(script.remoteCommandShellQuoted) cmux-et-probe \(terminalPath.remoteCommandShellQuoted) 2>/dev/null"
        } else {
            remoteCapabilityCommand = RemoteExecutableCommandBuilder(
                executableName: "etterminal",
                notFoundSentinel: "cmux-et: remote etterminal not found"
            ).resolutionProbeShellCommand + " 2>/dev/null"
        }
        let capabilityProbe = (capabilityProbeSSHArguments + ["-T", destination, remoteCapabilityCommand])
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        let hostNameQuery = (capabilityProbeSSHArguments + ["-G", destination])
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        let quotedClientArguments = clientArguments(terminalPathArguments: [])
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        var script = [
            "cmux_et_fallback() { exec /bin/sh -c \(sshFallbackCommand.remoteCommandShellQuoted); }",
            "cmux_et=\"$(\(localResolver.resolutionProbeShellCommand) 2>/dev/null)\"",
            "cmux_et_resolve_status=$?",
            "if [ \"$cmux_et_resolve_status\" -ne 0 ] || [ -z \"$cmux_et\" ]; then",
            "  printf '%s\\n' \(messages.localMissing.remoteCommandShellQuoted) >&2",
            "  cmux_et_fallback",
            "fi",
            "unset cmux_et_resolve_status",
        ]
        let reportsTerminalLifecycle = remoteRelayPort.map { (1...65_535).contains($0) } ?? false
        if reportsTerminalLifecycle {
            script += [
                "CMUX_SSH_ATTEMPT_ID=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || cmux_et_fallback",
                "export CMUX_SSH_ATTEMPT_ID",
            ]
        }
        if let preparationShellScript = preparationShellScript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preparationShellScript.isEmpty {
            script += [
                preparationShellScript,
                "cmux_et_prepare_status=$?",
                "if [ \"$cmux_et_prepare_status\" -ne 0 ]; then",
                "  printf '%s\\n' \(messages.remoteBootstrapInstallFailed.remoteCommandShellQuoted) >&2",
                "  cmux_et_fallback",
                "fi",
                "unset cmux_et_prepare_status cmux_remote_install_status",
            ]
        }
        script += [
            "cmux_et_terminal_path=\"$(\(capabilityProbe) </dev/null)\"",
            "cmux_et_probe_status=$?",
            "if [ \"$cmux_et_probe_status\" -eq 127 ]; then",
            "  printf '%s\\n' \(messages.remoteMissing.remoteCommandShellQuoted) >&2",
            "  cmux_et_fallback",
            "fi",
            "if [ \"$cmux_et_probe_status\" -ne 0 ]; then",
            "  printf '%s\\n' \(messages.remoteProbeFailed.remoteCommandShellQuoted) >&2",
            "  cmux_et_fallback",
            "fi",
            // Remote shell startup files may print before the probe; its
            // path is the last line, and anything but an absolute path is a
            // failed probe.
            "cmux_et_terminal_path=\"$(printf '%s\\n' \"$cmux_et_terminal_path\" | /usr/bin/tail -n 1)\"",
            "case \"$cmux_et_terminal_path\" in",
            "  /*) ;;",
            "  *) printf '%s\\n' \(messages.remoteProbeFailed.remoteCommandShellQuoted) >&2; cmux_et_fallback ;;",
            "esac",
            "unset cmux_et_probe_status",
            // ET connects to the SSH-resolved HostName, so probe that host.
            "cmux_et_ssh_config=\"$(\(hostNameQuery) 2>/dev/null)\"",
            "cmux_et_config_status=$?",
            "cmux_et_host=\"$(printf '%s\\n' \"$cmux_et_ssh_config\" | /usr/bin/awk '$1 == \"hostname\" { print $2; exit }')\"",
            "cmux_et_jump=\"$(printf '%s\\n' \"$cmux_et_ssh_config\" | /usr/bin/awk '$1 == \"proxyjump\" { print $2; exit }')\"",
            "cmux_et_nc=\"$(command -v /usr/bin/nc 2>/dev/null || true)\"",
            // Without a local probe tool, or behind a ProxyJump host whose
            // etserver ET may use instead, let ET report its own error.
            "if [ \"$cmux_et_config_status\" -eq 0 ] && [ -n \"$cmux_et_host\" ] && [ -n \"$cmux_et_nc\" ] && { [ -z \"$cmux_et_jump\" ] || [ \"$cmux_et_jump\" = none ]; } && ! \"$cmux_et_nc\" -z -G 5 -w 5 \"$cmux_et_host\" \(options.effectiveServerPort) >/dev/null 2>&1; then",
            "  printf '%s\\n' \(messages.serverUnreachable.remoteCommandShellQuoted) >&2",
            "  cmux_et_fallback",
            "fi",
            "unset cmux_et_ssh_config cmux_et_config_status cmux_et_host cmux_et_jump cmux_et_nc",
        ]
        if let managementReadyShellScript = managementReadyShellScript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !managementReadyShellScript.isEmpty {
            script.append(managementReadyShellScript)
        }
        if reportsTerminalLifecycle {
            script += terminalLifecycleRegistrationShellLines()
        }
        // Keep the fallback's self-deleting launchers until ET's outcome and
        // the user's recovery decision are known. EXIT and terminal signals
        // clean them up when no fallback takes ownership.
        let launcherCleanup = sshFallbackLauncherPaths.isEmpty ? ":" :
            "rm -f -- " + sshFallbackLauncherPaths.map(\.remoteCommandShellQuoted).joined(separator: " ")
        script += [
            "cmux_et_tty_state=",
            "if [ -t 0 ]; then cmux_et_tty_state=$(stty -g <&0 2>/dev/null) || cmux_et_tty_state=; fi",
            "cmux_et_restore_tty() { if [ -n \"$cmux_et_tty_state\" ]; then stty \"$cmux_et_tty_state\" <&0 2>/dev/null || :; fi; }",
            "cmux_et_cleanup() { cmux_et_restore_tty; \(launcherCleanup); }",
            "unset cmux_et_pid",
            "cmux_et_stop() { trap '' HUP INT TERM; if [ -n \"${cmux_et_pid:-}\" ]; then kill -s \"$1\" \"$cmux_et_pid\" 2>/dev/null || :; wait \"$cmux_et_pid\" 2>/dev/null || :; fi; exit \"$2\"; }",
            "trap cmux_et_cleanup 0",
            "trap 'cmux_et_stop HUP 129' HUP",
            // A background child's INT starts ignored until ET installs its
            // handler. TERM also cancels that startup window without a hang.
            "trap 'cmux_et_stop TERM 130' INT",
            "trap 'cmux_et_stop TERM 143' TERM",
        ]
        // ET splices --terminal-path unquoted into its remote shell command,
        // so a path with shell-special characters is single-quoted for it.
        script.append(
            #"case "$cmux_et_terminal_path" in *[!A-Za-z0-9/._+@%:=,-]*) "#
                + #"cmux_et_terminal_path="'$(printf '%s' "$cmux_et_terminal_path" | /usr/bin/sed "s/'/'\\\\''/g")'" ;; esac"#
        )
        script += [
            // Explicit stdin keeps the foreground terminal attached while the
            // wrapper owns the PID and forwards terminal shutdown signals.
            "\"$cmux_et\" --terminal-path \"$cmux_et_terminal_path\" \(quotedClientArguments) <&0 &",
            "cmux_et_pid=$!",
            "wait \"$cmux_et_pid\"",
            "cmux_et_status=$?",
            "unset cmux_et_pid",
            "cmux_et_restore_tty",
            // ET has no cross-version startup-complete signal. A nonzero
            // exit may follow an established session; never replay it on its
            // own, including when the caller is noninteractive.
            // ET's signal handlers return raw signal numbers (2/15), so
            // only its generic error (1) offers user-confirmed recovery.
            "if [ \"$cmux_et_status\" -eq 1 ] && [ -t 0 ]; then",
            "  printf '%s\\n' \(messages.startupRecoveryPrompt.remoteCommandShellQuoted) >&2",
            "  if IFS= read -r cmux_et_retry && [ \"$cmux_et_retry\" = ssh ]; then",
            "    trap - 0 HUP INT TERM",
            "    cmux_et_fallback",
            "  fi",
            "fi",
            "exit \"$cmux_et_status\"",
        ]
        return "/bin/sh -c \(script.joined(separator: "\n").remoteCommandShellQuoted)"
    }

    private func terminalLifecycleRegistrationShellLines() -> [String] {
        [
            "cmux_et_lifecycle_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_et_lifecycle_cli\" ] || [ ! -x \"$cmux_et_lifecycle_cli\" ]; then cmux_et_lifecycle_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -z \"$cmux_et_lifecycle_cli\" ] || [ -z \"${CMUX_SOCKET_PATH:-}\" ] || [ -z \"${CMUX_WORKSPACE_ID:-}\" ] || [ -z \"${CMUX_SURFACE_ID:-}\" ] || [ -z \"${CMUX_TERMINAL_LIFECYCLE_ID:-}\" ]; then cmux_et_fallback; fi",
            "cmux_et_launch_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"terminal_lifecycle_id\\\":\\\"$CMUX_TERMINAL_LIFECYCLE_ID\\\",\\\"attempt_id\\\":\\\"$CMUX_SSH_ATTEMPT_ID\\\"}\"",
            // ET exposes no post-connect callback, so like Mosh this launcher
            // registers the attempt but never claims connected readiness.
            "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=2 \"$cmux_et_lifecycle_cli\" --socket \"$CMUX_SOCKET_PATH\" rpc workspace.remote.terminal_session_launching \"$cmux_et_launch_payload\" >/dev/null 2>&1 || cmux_et_fallback",
            "unset cmux_et_launch_payload cmux_et_lifecycle_cli",
        ]
    }
}
