internal import Foundation

/// Builds a Mosh terminal command with explicit SSH capability fallback.
///
/// The builder receives complete SSH argument prefixes from the caller so the
/// Mosh capability probe and bootstrap honor the same host alias, identity,
/// port, and OpenSSH options as the workspace control connection.
public struct MoshTerminalCommandBuilder: Sendable {
    private let capabilityProbeSSHArguments: [String]
    private let sessionSSHArguments: [String]
    private let localMoshExecutableName: String
    private let destination: String
    private let remoteCommandArguments: [String]
    private let remoteRelayPort: Int?
    private let remoteIPMode: MoshRemoteIPMode
    private let preparationShellScript: String?
    private let managementReadyShellScript: String?
    private let sshFallbackCommand: String
    private let localMoshMissingMessage: String
    private let localMoshUnsupportedMessage: String
    private let remoteMoshMissingMessage: String
    private let remoteMoshProbeFailedMessage: String
    private let remoteBootstrapInstallFailedMessage: String
    private let remoteMoshAddressFallbackMessage: String

    /// Creates a Mosh terminal command builder.
    ///
    /// - Parameters:
    ///   - localMoshExecutableName: Local executable basename; injectable for deterministic tests.
    ///   - capabilityProbeSSHArguments: SSH executable and options used to check for `mosh-server`.
    ///   - sessionSSHArguments: SSH executable and options passed to Mosh's `--ssh` bootstrap.
    ///   - destination: SSH destination or host alias.
    ///   - remoteCommandArguments: Optional command argv launched by `mosh-server`.
    ///   - remoteRelayPort: Optional remote relay whose presence enables authoritative lifecycle attempt registration.
    ///   - remoteIPMode: Address-discovery mode passed to Mosh; remote mode falls back to SSH proxy resolution when SSH advertises an unusable address.
    ///   - preparationShellScript: Optional local preparation run before capability checks.
    ///   - managementReadyShellScript: Optional local callback run after SSH preparation succeeds and before Mosh starts.
    ///   - sshFallbackCommand: Complete local SSH terminal command used when Mosh is unavailable.
    ///   - localMoshMissingMessage: User-facing message printed when no local `mosh` executable exists.
    ///   - localMoshUnsupportedMessage: User-facing message printed when local Mosh lacks the required remote-IP mode.
    ///   - remoteMoshMissingMessage: User-facing message printed when `mosh-server` is absent remotely.
    ///   - remoteMoshProbeFailedMessage: User-facing message printed when the remote capability probe fails.
    ///   - remoteBootstrapInstallFailedMessage: User-facing message printed when bootstrap staging fails.
    ///   - remoteMoshAddressFallbackMessage: User-facing message printed when SSH proxy address resolution is selected automatically.
    public init(
        capabilityProbeSSHArguments: [String],
        sessionSSHArguments: [String],
        localMoshExecutableName: String = "mosh",
        destination: String,
        remoteCommandArguments: [String],
        remoteRelayPort: Int? = nil,
        remoteIPMode: MoshRemoteIPMode = .remote,
        preparationShellScript: String? = nil,
        managementReadyShellScript: String? = nil,
        sshFallbackCommand: String,
        localMoshMissingMessage: String,
        localMoshUnsupportedMessage: String,
        remoteMoshMissingMessage: String,
        remoteMoshProbeFailedMessage: String,
        remoteBootstrapInstallFailedMessage: String,
        remoteMoshAddressFallbackMessage: String
    ) {
        self.capabilityProbeSSHArguments = capabilityProbeSSHArguments
        self.sessionSSHArguments = sessionSSHArguments
        self.localMoshExecutableName = localMoshExecutableName
        self.destination = destination
        self.remoteCommandArguments = remoteCommandArguments
        self.remoteRelayPort = remoteRelayPort
        self.remoteIPMode = remoteIPMode
        self.preparationShellScript = preparationShellScript
        self.managementReadyShellScript = managementReadyShellScript
        self.sshFallbackCommand = sshFallbackCommand
        self.localMoshMissingMessage = localMoshMissingMessage
        self.localMoshUnsupportedMessage = localMoshUnsupportedMessage
        self.remoteMoshMissingMessage = remoteMoshMissingMessage
        self.remoteMoshProbeFailedMessage = remoteMoshProbeFailedMessage
        self.remoteBootstrapInstallFailedMessage = remoteBootstrapInstallFailedMessage
        self.remoteMoshAddressFallbackMessage = remoteMoshAddressFallbackMessage
    }

    /// Returns a shell command that launches Mosh or falls back to SSH.
    ///
    /// Capability detection happens before Mosh starts: the local executable is
    /// resolved from `PATH`, then the remote host is checked for `mosh-server`
    /// through the supplied SSH management lane. Exit status 127 represents an
    /// honest remote-missing result; other probe failures use the generic SSH
    /// fallback without pretending Mosh support was confirmed.
    ///
    /// - Returns: A complete `/bin/sh -c` terminal startup command.
    public func command() -> String {
        let localMoshResolver = RemoteExecutableCommandBuilder(
            executableName: localMoshExecutableName,
            notFoundSentinel: "cmux-mosh: local mosh not found"
        )
        let remoteMoshServerResolver = RemoteExecutableCommandBuilder(
            executableName: "mosh-server",
            notFoundSentinel: "cmux-mosh: remote mosh-server not found"
        )
        let remoteCapabilityCommand =
            remoteMoshServerResolver.resolutionProbeShellCommand + " >/dev/null 2>&1"
        let capabilityProbe = (capabilityProbeSSHArguments + [
            "-T",
            destination,
            remoteCapabilityCommand,
        ])
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        let remoteSSHConnectionScript = "printf '%s\\n' \"__CMUX_SSH_CONNECTION__${SSH_CONNECTION:-}\""
        let remoteSSHConnectionCommand = "/bin/sh -c \(remoteSSHConnectionScript.remoteCommandShellQuoted)"
        let remoteSSHConnectionProbe = (capabilityProbeSSHArguments + [
            "-T",
            destination,
            remoteSSHConnectionCommand,
        ])
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        let moshSSHCommand = sessionSSHArguments
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        let moshArguments = ([
            "--ssh=\(moshSSHCommand)",
            "--server=\(remoteMoshServerResolver.remoteExecPrefixShellCommand)",
            "--",
            destination,
        ] + remoteCommandArguments)
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        var script = [
            "cmux_mosh_fallback() { exec /bin/sh -c \(sshFallbackCommand.remoteCommandShellQuoted); }",
            "cmux_mosh=\"$(\(localMoshResolver.resolutionProbeShellCommand) 2>/dev/null)\"",
            "cmux_mosh_resolve_status=$?",
            "if [ \"$cmux_mosh_resolve_status\" -ne 0 ] || [ -z \"$cmux_mosh\" ]; then",
            "  printf '%s\\n' \(localMoshMissingMessage.remoteCommandShellQuoted) >&2",
            "  cmux_mosh_fallback",
            "fi",
            "unset cmux_mosh_resolve_status",
            "cmux_mosh_help=$(\"$cmux_mosh\" --help 2>&1 || true)",
            "case \"$cmux_mosh_help\" in",
            "  *--experimental-remote-ip=*) ;;",
            "  *)",
            "    printf '%s\\n' \(localMoshUnsupportedMessage.remoteCommandShellQuoted) >&2",
            "    cmux_mosh_fallback",
            "    ;;",
            "esac",
            "unset cmux_mosh_help",
        ]
        let reportsTerminalLifecycle = remoteRelayPort.map { (1...65_535).contains($0) } ?? false
        if reportsTerminalLifecycle {
            script += terminalLifecycleAttemptShellLines()
        }
        if let preparationShellScript = preparationShellScript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preparationShellScript.isEmpty {
            script += [
                preparationShellScript,
                "cmux_mosh_prepare_status=$?",
                "if [ \"$cmux_mosh_prepare_status\" -ne 0 ]; then",
                "  printf '%s\\n' \(remoteBootstrapInstallFailedMessage.remoteCommandShellQuoted) >&2",
                "  cmux_mosh_fallback",
                "fi",
                "unset cmux_mosh_prepare_status cmux_remote_install_status",
            ]
        }
        script += [
            "cmux_mosh_remote_ip_mode=\(remoteIPMode.rawValue.remoteCommandShellQuoted)",
            "cmux_mosh_address_fallback=0",
        ]
        script += [
            capabilityProbe,
            "cmux_mosh_probe_status=$?",
            "if [ \"$cmux_mosh_probe_status\" -eq 127 ]; then",
            "  printf '%s\\n' \(remoteMoshMissingMessage.remoteCommandShellQuoted) >&2",
            "  cmux_mosh_fallback",
            "fi",
            "if [ \"$cmux_mosh_probe_status\" -ne 0 ]; then",
            "  printf '%s\\n' \(remoteMoshProbeFailedMessage.remoteCommandShellQuoted) >&2",
            "  cmux_mosh_fallback",
            "fi",
        ]
        if remoteIPMode == .remote {
            // Mosh parses SSH_CONNECTION as four space-separated fields with
            // numeric ports and uses only the server address for its UDP
            // session, so validate exactly that shape and no more. When the
            // advertised address is unusable (empty, malformed, wildcard, or
            // loopback, which is what a port-forwarded SSH alias reports),
            // fall back to Mosh's proxy resolution: unlike local mode it
            // honors SSH aliases without requiring DNS on the destination.
            script += [
                "cmux_mosh_ssh_connection_probe_status=0",
                "cmux_mosh_ssh_connection_probe=\"$(\(remoteSSHConnectionProbe) 2>/dev/null)\" || cmux_mosh_ssh_connection_probe_status=$?",
                "case \"$cmux_mosh_ssh_connection_probe\" in *__CMUX_SSH_CONNECTION__*) cmux_mosh_ssh_connection=\"${cmux_mosh_ssh_connection_probe##*__CMUX_SSH_CONNECTION__}\" ;; *) cmux_mosh_ssh_connection= ;; esac",
                "if [ \"$cmux_mosh_ssh_connection_probe_status\" -ne 0 ] || [ -z \"$cmux_mosh_ssh_connection\" ]; then",
                "  cmux_mosh_address_fallback=1",
                "else",
                "  case \"$cmux_mosh_ssh_connection\" in",
                "    *' '*' '*' '*)",
                "      cmux_mosh_ssh_connection_tail=\"${cmux_mosh_ssh_connection#* }\"",
                "      cmux_mosh_ssh_peer_port=\"${cmux_mosh_ssh_connection_tail%% *}\"",
                "      cmux_mosh_ssh_connection_tail=\"${cmux_mosh_ssh_connection_tail#* }\"",
                "      cmux_mosh_ssh_server_ip=\"${cmux_mosh_ssh_connection_tail%% *}\"",
                "      cmux_mosh_ssh_connection_tail=\"${cmux_mosh_ssh_connection_tail#* }\"",
                "      cmux_mosh_ssh_server_port=\"${cmux_mosh_ssh_connection_tail%% *}\"",
                "      case \"$cmux_mosh_ssh_peer_port\" in ''|*[!0-9]*) cmux_mosh_address_fallback=1 ;; esac",
                "      case \"$cmux_mosh_ssh_server_port\" in ''|*[!0-9]*) cmux_mosh_address_fallback=1 ;; esac",
                "      case \"$cmux_mosh_ssh_server_ip\" in ''|0.0.0.0|::|::0|::1|127.*) cmux_mosh_address_fallback=1 ;; *[!0-9A-Fa-f:.]*) cmux_mosh_address_fallback=1 ;; esac",
                "      ;;",
                "    *) cmux_mosh_address_fallback=1 ;;",
                "  esac",
                "fi",
                "if [ \"$cmux_mosh_address_fallback\" -eq 1 ]; then cmux_mosh_remote_ip_mode=proxy; fi",
                "unset cmux_mosh_ssh_connection_probe_status cmux_mosh_ssh_connection_probe cmux_mosh_ssh_connection cmux_mosh_ssh_peer_port cmux_mosh_ssh_connection_tail cmux_mosh_ssh_server_ip cmux_mosh_ssh_server_port",
            ]
        }
        script += [
            "if [ \"$cmux_mosh_address_fallback\" -eq 1 ]; then",
            "  printf '%s\\n' \(remoteMoshAddressFallbackMessage.remoteCommandShellQuoted) >&2",
            "fi",
            "unset cmux_mosh_probe_status cmux_mosh_address_fallback",
        ]
        if let managementReadyShellScript = managementReadyShellScript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !managementReadyShellScript.isEmpty {
            script.append(managementReadyShellScript)
        }
        if reportsTerminalLifecycle {
            script += terminalLifecycleRegistrationShellLines()
        }
        // Mosh exposes no reliable post-UDP-handshake callback, so this
        // pre-exec launcher must not claim authoritative connected readiness.
        script.append("exec \"$cmux_mosh\" \"--experimental-remote-ip=$cmux_mosh_remote_ip_mode\" \(moshArguments)")
        return "/bin/sh -c \(script.joined(separator: "\n").remoteCommandShellQuoted)"
    }

    private func terminalLifecycleAttemptShellLines() -> [String] {
        [
            "CMUX_SSH_ATTEMPT_ID=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || cmux_mosh_fallback",
            "export CMUX_SSH_ATTEMPT_ID",
        ]
    }

    private func terminalLifecycleRegistrationShellLines() -> [String] {
        [
            "cmux_mosh_lifecycle_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_mosh_lifecycle_cli\" ] || [ ! -x \"$cmux_mosh_lifecycle_cli\" ]; then cmux_mosh_lifecycle_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -z \"$cmux_mosh_lifecycle_cli\" ] || [ -z \"${CMUX_SOCKET_PATH:-}\" ] || [ -z \"${CMUX_WORKSPACE_ID:-}\" ] || [ -z \"${CMUX_SURFACE_ID:-}\" ] || [ -z \"${CMUX_TERMINAL_LIFECYCLE_ID:-}\" ]; then cmux_mosh_fallback; fi",
            "cmux_mosh_lifecycle_rpc() { cmux_mosh_lifecycle_method=\"$1\"; cmux_mosh_lifecycle_payload=\"$2\"; cmux_mosh_lifecycle_retry=0; while ! CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=2 \"$cmux_mosh_lifecycle_cli\" --socket \"$CMUX_SOCKET_PATH\" rpc \"$cmux_mosh_lifecycle_method\" \"$cmux_mosh_lifecycle_payload\" >/dev/null 2>&1; do cmux_mosh_lifecycle_retry=$((cmux_mosh_lifecycle_retry + 1)); if [ \"$cmux_mosh_lifecycle_retry\" -ge 4 ]; then return 1; fi; /bin/sleep 0.1; done; }",
            "cmux_mosh_launch_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"terminal_lifecycle_id\\\":\\\"$CMUX_TERMINAL_LIFECYCLE_ID\\\",\\\"attempt_id\\\":\\\"$CMUX_SSH_ATTEMPT_ID\\\"}\"",
            "cmux_mosh_lifecycle_rpc workspace.remote.terminal_session_launching \"$cmux_mosh_launch_payload\" || cmux_mosh_fallback",
            "unset cmux_mosh_launch_payload cmux_mosh_lifecycle_cli cmux_mosh_lifecycle_method cmux_mosh_lifecycle_payload cmux_mosh_lifecycle_retry",
            "unset -f cmux_mosh_lifecycle_rpc 2>/dev/null || true",
        ]
    }
}
