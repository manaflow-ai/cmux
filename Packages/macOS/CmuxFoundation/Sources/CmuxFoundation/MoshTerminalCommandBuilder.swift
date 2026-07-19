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
    private let preparationShellScript: String?
    private let sshFallbackCommand: String
    private let localMoshMissingMessage: String
    private let localMoshUnsupportedMessage: String
    private let remoteMoshMissingMessage: String
    private let remoteMoshProbeFailedMessage: String

    /// Creates a Mosh terminal command builder.
    ///
    /// - Parameters:
    ///   - localMoshExecutableName: Local executable basename; injectable for deterministic tests.
    ///   - capabilityProbeSSHArguments: SSH executable and options used to check for `mosh-server`.
    ///   - sessionSSHArguments: SSH executable and options passed to Mosh's `--ssh` bootstrap.
    ///   - destination: SSH destination or host alias.
    ///   - remoteCommandArguments: Optional command argv launched by `mosh-server`.
    ///   - preparationShellScript: Optional local preparation run after capability checks.
    ///   - sshFallbackCommand: Complete local SSH terminal command used when Mosh is unavailable.
    ///   - localMoshMissingMessage: User-facing message printed when no local `mosh` executable exists.
    ///   - localMoshUnsupportedMessage: User-facing message printed when local Mosh lacks the required remote-IP mode.
    ///   - remoteMoshMissingMessage: User-facing message printed when `mosh-server` is absent remotely.
    ///   - remoteMoshProbeFailedMessage: User-facing message printed when the remote capability probe fails.
    public init(
        capabilityProbeSSHArguments: [String],
        sessionSSHArguments: [String],
        localMoshExecutableName: String = "mosh",
        destination: String,
        remoteCommandArguments: [String],
        preparationShellScript: String? = nil,
        sshFallbackCommand: String,
        localMoshMissingMessage: String,
        localMoshUnsupportedMessage: String,
        remoteMoshMissingMessage: String,
        remoteMoshProbeFailedMessage: String
    ) {
        self.capabilityProbeSSHArguments = capabilityProbeSSHArguments
        self.sessionSSHArguments = sessionSSHArguments
        self.localMoshExecutableName = localMoshExecutableName
        self.destination = destination
        self.remoteCommandArguments = remoteCommandArguments
        self.preparationShellScript = preparationShellScript
        self.sshFallbackCommand = sshFallbackCommand
        self.localMoshMissingMessage = localMoshMissingMessage
        self.localMoshUnsupportedMessage = localMoshUnsupportedMessage
        self.remoteMoshMissingMessage = remoteMoshMissingMessage
        self.remoteMoshProbeFailedMessage = remoteMoshProbeFailedMessage
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
            .map(shellQuote)
            .joined(separator: " ")
        let moshSSHCommand = sessionSSHArguments
            .map(shellQuote)
            .joined(separator: " ")
        let moshArguments = ([
            "--experimental-remote-ip=remote",
            "--ssh=\(moshSSHCommand)",
            "--server=\(remoteMoshServerResolver.remoteExecPrefixShellCommand)",
            "--",
            destination,
        ] + remoteCommandArguments)
            .map(shellQuote)
            .joined(separator: " ")
        let fallback = "exec /bin/sh -c \(shellQuote(sshFallbackCommand))"
        var script = [
            "cmux_mosh=\"$(\(localMoshResolver.resolutionProbeShellCommand) 2>/dev/null)\"",
            "cmux_mosh_resolve_status=$?",
            "if [ \"$cmux_mosh_resolve_status\" -ne 0 ] || [ -z \"$cmux_mosh\" ]; then",
            "  printf '%s\\n' \(shellQuote(localMoshMissingMessage)) >&2",
            "  \(fallback)",
            "fi",
            "unset cmux_mosh_resolve_status",
            "cmux_mosh_help=$(\"$cmux_mosh\" --help 2>&1 || true)",
            "case \"$cmux_mosh_help\" in",
            "  *--experimental-remote-ip=*) ;;",
            "  *)",
            "    printf '%s\\n' \(shellQuote(localMoshUnsupportedMessage)) >&2",
            "    \(fallback)",
            "    ;;",
            "esac",
            "unset cmux_mosh_help",
            capabilityProbe,
            "cmux_mosh_probe_status=$?",
            "if [ \"$cmux_mosh_probe_status\" -eq 127 ]; then",
            "  printf '%s\\n' \(shellQuote(remoteMoshMissingMessage)) >&2",
            "  \(fallback)",
            "fi",
            "if [ \"$cmux_mosh_probe_status\" -ne 0 ]; then",
            "  printf '%s\\n' \(shellQuote(remoteMoshProbeFailedMessage)) >&2",
            "  \(fallback)",
            "fi",
            "unset cmux_mosh_probe_status",
        ]
        if let preparationShellScript = preparationShellScript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preparationShellScript.isEmpty {
            script += [
                preparationShellScript,
                "cmux_mosh_prepare_status=$?",
                "if [ \"$cmux_mosh_prepare_status\" -ne 0 ]; then",
                "  printf '%s\\n' \(shellQuote(remoteMoshProbeFailedMessage)) >&2",
                "  \(fallback)",
                "fi",
                "unset cmux_mosh_prepare_status cmux_remote_install_status",
            ]
        }
        script.append("exec \"$cmux_mosh\" \(moshArguments)")
        return "/bin/sh -c \(shellQuote(script.joined(separator: "\n")))"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
