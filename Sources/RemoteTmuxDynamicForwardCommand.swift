import Foundation

/// Argv construction and stderr classification for adding/removing a SOCKS5
/// dynamic forward on an ssh-tmux host's already-running ControlMaster, via
/// OpenSSH's multiplex `-O forward`/`-O cancel` commands. No process launching
/// here — that's ``RemoteTmuxSSHTransport``, which holds and injects one
/// instance. Instance methods rather than statics, so argv exactness and
/// stderr classification stay unit-testable without a real SSH process.
struct RemoteTmuxDynamicForwardCommand {
    init() {}

    /// `ssh -O forward -D 127.0.0.1:<localPort> -o ControlPath=<path> -- <destination>`.
    ///
    /// The bind address is always the literal `127.0.0.1`, never a bare port:
    /// a bare `-D <port>` honors `GatewayPorts`/`BindAddress` from the user's
    /// `ssh_config` and could expose the SOCKS listener on a LAN interface.
    /// This is a security requirement, not a style choice.
    func openArguments(controlSocketPath: String, destination: String, localPort: Int) -> [String] {
        [
            "-O", "forward",
            "-D", "127.0.0.1:\(localPort)",
            "-o", "ControlPath=\(controlSocketPath)",
            "--", destination,
        ]
    }

    /// The inverse of ``openArguments(controlSocketPath:destination:localPort:)``.
    func cancelArguments(controlSocketPath: String, destination: String, localPort: Int) -> [String] {
        [
            "-O", "cancel",
            "-D", "127.0.0.1:\(localPort)",
            "-o", "ControlPath=\(controlSocketPath)",
            "--", destination,
        ]
    }

    /// Why an `-O forward`/`-O cancel` invocation failed, from its exit code
    /// and stderr text. `nil` means the command succeeded; a failure that
    /// didn't match a known OpenSSH message classifies as `.unknown`.
    enum Failure: Equatable {
        /// The ControlMaster is gone (socket missing, stale, or never opened).
        case masterGone
        /// The requested local port is already bound by something else.
        case portInUse
        /// The remote sshd config disallows this forward
        /// (`AllowTcpForwarding no`, a `PermitOpen`/`PermitListen` restriction).
        case forwardingDisallowed
        case unknown(String)
    }

    /// Matches specific OpenSSH phrases, never broad substrings: looser
    /// candidates like `"bind: "` or `"open failed"` were tried and dropped
    /// because they also match unrelated failures, and a misclassification
    /// makes the registry retry or give up on the wrong signal.
    func classify(exitCode: Int32, stderr: String) -> Failure? {
        guard exitCode != 0 else { return nil }
        let text = stderr.lowercased()

        if text.contains("control socket connect")
            || text.contains("no such file or directory")
            || text.contains("not a controlling master") {
            return .masterGone
        }
        if text.contains("address already in use")
            || text.contains("cannot listen to port") {
            return .portInUse
        }
        if text.contains("administratively prohibited") {
            return .forwardingDisallowed
        }
        return .unknown(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A classified `-O forward`/`-O cancel` failure, thrown by
/// `RemoteTmuxSSHTransport.openDynamicForward(localPort:)` so the
/// browser-proxy registry can react to *why* it failed — `.portInUse` is
/// retryable with a fresh port, the others are not.
struct RemoteTmuxDynamicForwardError: Error, Equatable {
    let failure: RemoteTmuxDynamicForwardCommand.Failure
    let exitCode: Int32
    let stderr: String
}
