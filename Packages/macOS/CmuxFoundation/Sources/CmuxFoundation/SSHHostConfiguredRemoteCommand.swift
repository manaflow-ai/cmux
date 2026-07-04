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
public enum SSHHostConfiguredRemoteCommand {
    /// `RemoteCommand=none` — the option text for string-composed ssh
    /// command lines.
    public static let overrideOption = "RemoteCommand=none"

    /// `-o RemoteCommand=none` as an argv fragment, inserted before the
    /// destination.
    public static let overrideArguments: [String] = ["-o", overrideOption]
}
