import Foundation

/// Neutralizes a host-configured OpenSSH `RemoteCommand` for cmux-controlled
/// invocations that supply their own remote command.
///
/// A host alias configured for interactive logins, e.g.
///
///     Host dev-host
///       RequestTTY yes
///       RemoteCommand sudo su -
///
/// makes OpenSSH abort any `ssh dev-host <command>` with "Cannot execute
/// command-line and remote command." (exit 255), because a command-line
/// command and a configured `RemoteCommand` are mutually exclusive
/// (https://github.com/manaflow-ai/cmux/issues/7246). Every cmux-built ssh
/// argv that appends its own command — auth probes, bootstrap installers,
/// the cmuxd stdio transport, port scans, tmux mirror commands, cleanup
/// hops — must therefore override the configured value with
/// `RemoteCommand=none` (supported since OpenSSH 7.6; macOS has shipped
/// newer clients since 10.13.2).
///
/// OpenSSH uses the first obtained value per option, so insert the override
/// ahead of caller-supplied `-o` options where the builder allows: an
/// earlier `none` then also wins over a stray user-provided `RemoteCommand`
/// option, which would break cmux plumbing the same way. Session
/// invocations that intentionally carry cmux's own
/// `-o RemoteCommand=<bootstrap>` — or run no remote command at all — must
/// not apply this override.
public struct SSHHostConfiguredRemoteCommand: Sendable {
    /// `RemoteCommand=none` — the option text for string-composed ssh
    /// command lines.
    public let overrideOption = "RemoteCommand=none"

    /// `-o RemoteCommand=none` as an argv fragment, inserted before the
    /// destination.
    public var overrideArguments: [String] { ["-o", overrideOption] }

    public init() {}

    /// Parses the effective `RemoteCommand` from `ssh -G` output.
    ///
    /// OpenSSH expands supported percent tokens before its `config_test`
    /// (`-G`) dump, so the returned value is already the command that SSH
    /// would send and must not be expanded a second time.
    ///
    /// - Parameter output: Standard output from `ssh -G <destination>`.
    /// - Returns: The configured command, or `nil` when OpenSSH reports `none`.
    public func configuredCommand(fromSSHConfigOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0].lowercased() == "remotecommand" else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.caseInsensitiveCompare("none") != .orderedSame else {
                return nil
            }
            return value
        }
        return nil
    }
}
