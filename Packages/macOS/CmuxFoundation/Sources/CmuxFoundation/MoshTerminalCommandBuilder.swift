internal import Foundation

/// Builds a Mosh terminal command with explicit SSH capability fallback.
///
/// The builder receives complete SSH argument prefixes from the caller so the
/// Mosh capability probe and bootstrap honor the same host alias, identity,
/// port, and OpenSSH options as the workspace control connection.
public struct MoshTerminalCommandBuilder: Sendable {
    private let capabilityProbeSSHArguments: [String]
    private let sessionSSHArguments: [String]
    private let destination: String
    private let remoteCommandArguments: [String]
    private let sshFallbackCommand: String
    private let localMoshMissingMessage: String
    private let localMoshUnsupportedMessage: String
    private let remoteMoshMissingMessage: String
    private let remoteMoshProbeFailedMessage: String

    /// Creates a Mosh terminal command builder.
    ///
    /// - Parameters:
    ///   - capabilityProbeSSHArguments: SSH executable and options used to check for `mosh-server`.
    ///   - sessionSSHArguments: SSH executable and options passed to Mosh's `--ssh` bootstrap.
    ///   - destination: SSH destination or host alias.
    ///   - remoteCommandArguments: Optional command argv launched by `mosh-server`.
    ///   - sshFallbackCommand: Complete local SSH terminal command used when Mosh is unavailable.
    ///   - localMoshMissingMessage: User-facing message printed when no local `mosh` executable exists.
    ///   - localMoshUnsupportedMessage: User-facing message printed when local Mosh lacks the required remote-IP mode.
    ///   - remoteMoshMissingMessage: User-facing message printed when `mosh-server` is absent remotely.
    ///   - remoteMoshProbeFailedMessage: User-facing message printed when the remote capability probe fails.
    public init(
        capabilityProbeSSHArguments: [String],
        sessionSSHArguments: [String],
        destination: String,
        remoteCommandArguments: [String],
        sshFallbackCommand: String,
        localMoshMissingMessage: String,
        localMoshUnsupportedMessage: String,
        remoteMoshMissingMessage: String,
        remoteMoshProbeFailedMessage: String
    ) {
        self.capabilityProbeSSHArguments = capabilityProbeSSHArguments
        self.sessionSSHArguments = sessionSSHArguments
        self.destination = destination
        self.remoteCommandArguments = remoteCommandArguments
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
        let remoteCapabilityCommand = "command -v mosh-server >/dev/null 2>&1 || exit 127"
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
        let moshCommand = ([
            "mosh",
            "--experimental-remote-ip=remote",
            "--ssh=\(moshSSHCommand)",
            "--",
            destination,
        ] + remoteCommandArguments)
            .map(shellQuote)
            .joined(separator: " ")
        let fallback = "exec /bin/sh -c \(shellQuote(sshFallbackCommand))"
        let script = [
            "if ! command -v mosh >/dev/null 2>&1; then",
            "  printf '%s\\n' \(shellQuote(localMoshMissingMessage)) >&2",
            "  \(fallback)",
            "fi",
            "cmux_mosh_help=$(mosh --help 2>&1 || true)",
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
            "exec \(moshCommand)",
        ].joined(separator: "\n")
        return "/bin/sh -c \(shellQuote(script))"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
