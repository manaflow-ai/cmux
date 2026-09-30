public import Foundation

/// Argument vectors for every process cmux starts to reach an SSH machine.
///
/// Transport choice: the bundled cmux-tui's own SSH carrier. `cmux-tui
/// remote connect ssh://host` runs the user's `/usr/bin/ssh -T host
/// ~/.local/bin/cmux-tui remote-link --stdio --session NAME` and carries
/// framed, resumable links over that one stdio stream (carrier
/// authentication: the SSH account is the identity). Locally it exposes a
/// Unix socket that speaks the same v12 protocol as the local daemon, so
/// the app attaches to it exactly like a Cloud machine's link. This beats
/// `ssh -L` Unix-socket forwarding: no remote socket path to guess, no
/// `StreamLocalBindUnlink`/stale-socket races, no `AllowStreamLocalForwarding`
/// requirement on the server, and the link resumes reliable sequence
/// numbers across short drops instead of resetting every attachment.
///
/// Every ssh gets ``enforcedOptions``: no prompts (the app has no TTY, so a
/// prompt would hang or fail obscurely), and no agent, X11 or port
/// forwarding back to this Mac (a remote machine must not reach local
/// resources through the link). Everything else stays the user's: their
/// `~/.ssh/config`, known_hosts and host key policy (never relaxed), agent,
/// ProxyJump and ControlMaster. cmux never handles a password.
public struct SSHCommandLine: Sendable {
    public static let systemSSH = "/usr/bin/ssh"

    /// Added to every ssh the app runs. `-o` on the command line wins over
    /// the config file only for these keys.
    public static let enforcedOptions: [String] = [
        "-oBatchMode=yes",
        "-oConnectTimeout=15",
        "-oForwardAgent=no",
        "-oForwardX11=no",
        "-oClearAllForwardings=yes",
        "-oPermitLocalCommand=no",
    ]

    /// Link retries inside one `remote connect` before it exits and the
    /// app's event-driven retry takes over.
    public static let linkReconnectAttempts = 5

    public var sshBinary: String

    public init(sshBinary: String = SSHCommandLine.systemSSH) {
        self.sshBinary = sshBinary
    }

    /// `ssh … host 'sh -s'`: the caller writes a POSIX script to stdin, so
    /// the user's login shell (bash, zsh, fish) only ever sees `sh -s`.
    public func script(_ host: SSHHost) -> [String] {
        var argv = [sshBinary, "-T"] + Self.enforcedOptions
        if let port = host.destination.port { argv += ["-p", String(port)] }
        argv += ["--", host.destination.sshArgument, "sh -s"]
        return argv
    }

    /// Arguments for the bundled `cmux-tui` (the executable is the caller's).
    /// `--no-install`: cmux-tui's own npm bootstrap never runs; the app
    /// installs the pinned build after the user confirms (RemoteInstallPlan).
    public func link(_ host: SSHHost, clientStateDir: String, localSocket: String) -> [String] {
        var args = [
            "remote", "connect", host.destination.route,
            "--session", host.session,
            "--headless", "--json", "--exit-with-parent",
            "--lanes", "single",
            "--no-install",
            "--ssh-binary", sshBinary,
            "--remote-binary", host.remoteBinary,
            "--state-dir", clientStateDir,
            "--local-socket", localSocket,
            "--connect-timeout-seconds", "30",
            "--reconnect-attempts", String(Self.linkReconnectAttempts),
        ]
        if let stateDir = host.remoteStateDir { args += ["--remote-state-dir", stateDir] }
        for option in Self.enforcedOptions { args += ["--ssh-arg", option] }
        return args
    }
}
