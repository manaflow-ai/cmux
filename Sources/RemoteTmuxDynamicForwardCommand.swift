import Foundation

/// Pure argv construction and stderr classification for adding/removing a
/// SOCKS5 dynamic forward on an ssh-tmux host's already-running SSH
/// ControlMaster, via OpenSSH's multiplex `-O forward`/`-O cancel` control
/// commands. No process launching here — that's `RemoteTmuxSSHTransport`.
/// Kept as pure functions specifically so argv exactness and stderr
/// classification are unit-testable without a real SSH process.
///
/// Static members only: pure argv/string transforms with no per-instance
/// state to hold (one-line justification per the no-namespace-enum
/// convention; see `LoopbackPortAllocator`/`RemoteLoopbackProxyAlias`).
enum RemoteTmuxDynamicForwardCommand {
    /// `ssh -O forward -D 127.0.0.1:<localPort> -o ControlPath=<path> -- <destination>`.
    ///
    /// The bind address is always the literal `127.0.0.1`, never a bare port:
    /// a bare `-D <port>` honors `GatewayPorts`/`BindAddress` from the user's
    /// `ssh_config` and could expose the SOCKS listener on a LAN interface.
    /// This is a security requirement, not a style choice.
    static func openArguments(controlSocketPath: String, destination: String, localPort: Int) -> [String] {
        [
            "-O", "forward",
            "-D", "127.0.0.1:\(localPort)",
            "-o", "ControlPath=\(controlSocketPath)",
            "--", destination,
        ]
    }

    /// The inverse of ``openArguments(controlSocketPath:destination:localPort:)``.
    static func cancelArguments(controlSocketPath: String, destination: String, localPort: Int) -> [String] {
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

    /// Matches specific OpenSSH phrases rather than broad substrings: several
    /// looser candidates (`"bind: "`, `"open failed"`, `"port forwarding
    /// failed"`) were tried and dropped because they also match unrelated
    /// failures (a plain bind permission error, an ordinary remote connection
    /// failure, a remote-side forwarding refusal distinct from a local port
    /// collision) — a wrong classification would make the registry retry or
    /// give up on the wrong signal.
    static func classify(exitCode: Int32, stderr: String) -> Failure? {
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
/// `RemoteTmuxSSHTransport.openDynamicForward(localPort:)` so callers (the
/// browser-proxy registry) can react to *why* it failed instead of retrying
/// or giving up on the wrong signal.
struct RemoteTmuxDynamicForwardError: Error, Equatable {
    let failure: RemoteTmuxDynamicForwardCommand.Failure
    let exitCode: Int32
    let stderr: String
}
