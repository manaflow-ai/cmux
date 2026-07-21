import Foundation

/// The transports cmux can carry a control stream over.
///
/// A closed set rather than a free-form string, so an unknown value is rejected at the
/// socket boundary instead of becoming an unspawnable host.
enum RemoteTmuxTransportKind: String, Sendable, Equatable, CaseIterable {
    /// Plain ssh over the shared ControlMaster: the default, and today's behavior.
    case ssh
    /// EternalTerminal: keeps its session across a network change, needs a tty.
    case et

    /// Parses a user-supplied value, rejecting anything unrecognized.
    static func parse(_ raw: String?) -> RemoteTmuxTransportKind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .ssh }
        return RemoteTmuxTransportKind(rawValue: raw)
    }

    /// The profile that carries this transport.
    func profile(port: Int?) -> RemoteTmuxTransportProfile {
        switch self {
        case .ssh:
            return RemoteTmuxSSHTransportProfile()
        case .et:
            // etserver listens on 2022 by default, and a host's `port` means "the port of
            // this host's transport" — for et that is etserver's, not sshd's.
            return RemoteTmuxETTransportProfile(
                port: port ?? 2022,
                // macOS servers keep etterminal outside the default remote PATH, which is
                // why `et` ships `--macserver` at all. Naming the path explicitly works on
                // every server rather than only that one flag's target.
                remoteTerminalPath: "/usr/local/bin/etterminal"
            )
        }
    }
}

/// How a remote tmux control stream and one-shot commands are carried to a host.
///
/// Today there is exactly one implementation and it is ssh, so this changes no behavior.
/// It exists because the choice of transport is currently spelled out at the point of use —
/// `Process` is handed `ssh` and `host.controlModeArguments(…)` directly — and any transport
/// that keeps a session alive across a network change (EternalTerminal, mosh) cannot be
/// introduced without first naming that decision.
///
/// The split is between *argv* and *execution*: this decides what to run, while
/// ``RemoteTmuxSSHTransport`` keeps owning process spawning, the shared ControlMaster, and
/// stderr classification. Keeping execution out means a second transport does not have to
/// reimplement any of that.
protocol RemoteTmuxTransportProfile: Sendable {
    /// The binary that carries the connection.
    func executablePath() -> String

    /// argv for the long-lived `tmux -CC` control stream.
    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) -> [String]

    /// argv for a one-shot remote command (discovery, mutations).
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String]

    /// Whether the transport needs a pseudo-terminal rather than pipes.
    ///
    /// Measured against EternalTerminal 6.2.11: with stdin at `/dev/null` and stdout a
    /// pipe, `et` writes nothing at all and aborts (`SIGABRT`) when the session ends — not
    /// even a trivial `echo` returns output. It is a terminal client and expects a tty.
    /// cmux spawns its control stream on pipes, so this is the one property that decides
    /// whether a transport can be spawned at all, independent of argv.
    var requiresPseudoTerminal: Bool { get }

    /// Whether the transport recovers from network loss by itself.
    ///
    /// This is the property that changes cmux's behavior rather than just its argv. cmux
    /// treats stdout EOF as "the stream died, respawn with backoff". A transport that
    /// reconnects internally produces no EOF for a network drop — the stream pauses and
    /// resumes — so respawning on a stall would throw away the session it was about to
    /// recover. Such a transport needs a liveness check (process alive plus a control-mode
    /// round-trip) instead of an EOF trigger.
    var reconnectsInternally: Bool { get }
}

/// What end-of-stream on the control connection means.
///
/// cmux's recovery is built on stdout EOF: the stream ends, so respawn with backoff. That
/// is right for ssh, where a dropped connection ends the process. It is wrong for a
/// transport that owns its own reconnection: such a transport does not end for a network
/// drop — the stream pauses and resumes — so if it *does* end, it has genuinely exited and
/// the session is over. Respawning then would be cmux fighting the transport for ownership
/// of recovery, and the failure it must watch for instead is "alive but wedged".
enum RemoteTmuxStreamEndDisposition: Sendable, Equatable {
    /// cmux owns recovery: respawn the transport with backoff.
    case reconnect
    /// The transport owned recovery, so its exit is terminal.
    case sessionOver

    /// Decides from who owns reconnection.
    static func forStreamEnd(reconnectsInternally: Bool) -> RemoteTmuxStreamEndDisposition {
        reconnectsInternally ? .sessionOver : .reconnect
    }
}

/// A command to run before opening a connection to a host.
///
/// Some hosts need a step cmux has no business knowing about: minting a short-lived
/// credential, unlocking an agent, refreshing a token. Rather than teaching cmux any of
/// them, a host can carry a command, run as `<command> <destination>`.
///
/// Two rules come out of wiring one of these up for real:
///
/// - It runs once per connection, not once per command. Anything minting a single-use
///   credential must not race itself — two mints can invalidate each other — so the right
///   home is the single-flight path that opens the shared master, not a per-command hook.
/// - A non-zero exit is not fatal. cmux proceeds and lets the connection fail on its own
///   terms, so a broken hook cannot make a host unreachable.
struct RemoteTmuxPreConnectHook: Sendable, Equatable {
    /// The executable to run. `nil` means today's behavior: no hook.
    let command: String?

    init(command: String? = nil) {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.command = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The argv to run for `destination`, or nil when no hook is configured.
    func argv(destination: String) -> [String]? {
        guard let command else { return nil }
        return [command, destination]
    }

    /// Whether a hook's exit status should abort the connection. It never should: see the
    /// type's documentation.
    func shouldAbortConnection(onExitCode code: Int32) -> Bool { false }
}

/// The ssh transport: current behavior, and the default.
struct RemoteTmuxSSHTransportProfile: RemoteTmuxTransportProfile {
    /// Idle lifetime of the shared master, matching ``RemoteTmuxSSHTransport``'s default so
    /// one-shot argv built here is identical to what the transport builds for itself.
    let controlPersistSeconds: Int

    init(controlPersistSeconds: Int = 180) {
        self.controlPersistSeconds = controlPersistSeconds
    }

    func executablePath() -> String {
        RemoteTmuxHost.defaultSSHExecutablePath()
    }

    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) -> [String] {
        host.controlModeArguments(sessionName: sessionName, createIfMissing: createIfMissing)
    }

    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        // `--` ends ssh option parsing so a destination beginning with `-` (e.g.
        // `-oProxyCommand=…`) can never be consumed as an ssh option.
        host.sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: true)
            + ["--", host.destination, remoteCommand]
    }

    /// ssh does not: a dropped connection ends the process, and cmux respawns it.
    var reconnectsInternally: Bool { false }

    /// ssh is happy on pipes, which is what cmux spawns today.
    var requiresPseudoTerminal: Bool { false }
}

/// How cmux gives a transport a controlling terminal.
///
/// cmux spawns its control stream on pipes, which a terminal client like EternalTerminal
/// refuses to work with. Rather than reimplement `posix_openpt`/`grantpt`/`TIOCSCTTY`
/// plumbing, wrap the transport in the system's own pty allocator, which is also how the
/// behavior was verified by hand.
///
/// Two measured facts make this safe for a control protocol:
///
/// - The pty echoes whatever cmux writes to stdin. Those echoed lines are not control-mode
///   notifications, so the parser ignores them; they cost bytes, not correctness.
/// - Anything written before the control stream is up is consumed by the transport's *login
///   shell*, not by tmux. cmux already withholds commands until `%enter`, so this is
///   already respected — but it is why that ordering is load-bearing rather than incidental.
enum RemoteTmuxPseudoTerminal {
    /// BSD `script` runs a command with a pty attached and copies the session to a file;
    /// `/dev/null` discards the copy while keeping the pty.
    static let allocatorPath = "/usr/bin/script"

    /// Wraps a transport invocation so the child gets a tty on stdin/stdout/stderr.
    static func wrap(executable: String, arguments: [String]) -> [String] {
        ["-q", "/dev/null", executable] + arguments
    }
}

/// EternalTerminal: a transport that keeps its session across a network change.
///
/// Every claim here was measured against et 6.2.11 on a loopback `etserver`, because the
/// differences from ssh are not the kind you can read off `--help`:
///
/// - **It needs a tty.** On pipes it emits nothing and aborts at session end.
/// - **It types the command into a login shell** rather than exec'ing it, appending
///   `; exit`. A real `tmux -CC` stream therefore arrives after ~1.2 KB of preamble: the
///   echoed command line, then prompt escapes, and only then `%begin`. cmux's parser
///   already tolerates this (unrecognized lines yield no messages) and already strips the
///   pty's `\r`, so the protocol survives — but the preamble is not optional, it is what
///   this transport always does.
/// - **It reconnects internally**, so a dropped network does not end the process. On a real
///   session end the client first attempts a reconnect and only then reports the session
///   gone, which is why EOF must mean "over" rather than "respawn" here.
/// - **`-x` / `--kill-other-sessions` must never be passed**: it kills every session that
///   user has on the host, not just stale ones.
struct RemoteTmuxETTransportProfile: RemoteTmuxTransportProfile {
    /// etserver's default port is 2022, not ssh's 22.
    let port: Int
    /// `et` binary path.
    let executable: String
    /// Path to `etterminal` on the server, needed when it is not on the remote PATH — which
    /// is the case for a macOS server, where `--macserver` exists to set exactly this.
    let remoteTerminalPath: String?

    init(
        port: Int = 2022,
        executable: String = "/usr/local/bin/et",
        remoteTerminalPath: String? = nil
    ) {
        self.port = port
        self.executable = executable
        self.remoteTerminalPath = remoteTerminalPath
    }

    func executablePath() -> String { executable }

    func controlStreamArgv(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) -> [String] {
        // Plain `tmux`, not the PATH resolver ssh needs, and the reason is a hard limit rather
        // than a preference. `et` does not exec the command: it types it into a login shell and
        // appends `; exit`. That shell reads from a pty in canonical mode, which delivers at
        // most MAX_CANON (1024 on macOS) bytes per line, and the resolver is ~1113 bytes. The
        // line never completes, so the shell runs nothing and the stream sits silent until the
        // attach times out — measured against et 6.2.11.
        //
        // Dropping the resolver is safe precisely because it is a login shell: it has the user's
        // full PATH, so it finds tmux itself. ssh is the opposite case, running a non-login shell
        // with a minimal PATH, which is why that profile still needs the resolver.
        let remote = ([
            "tmux",
            "-CC",
            createIfMissing ? "new-session" : "attach-session",
            "-t", sessionName,
        ] as [String])
            .map(RemoteTmuxHost.shellSingleQuoted)
            .joined(separator: " ")
        // Arguments only: the executable is supplied separately (see ``executablePath()``),
        // exactly as the ssh profile does. Including it here would pass `et` twice.
        var argv = ["-p", String(port)]
        if let remoteTerminalPath {
            argv += ["--terminal-path", remoteTerminalPath]
        }
        // `exec` so the login shell does not linger as a parent of tmux.
        argv += ["-c", "exec \(remote)", host.destination]
        return argv
    }

    /// One-shot commands keep riding ssh's shared master: it is already single-flighted for
    /// the cold-start burst, and that logic has nothing to do with how the `-CC` stream is
    /// carried.
    func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] {
        RemoteTmuxSSHTransportProfile().oneShotArgv(host: host, remoteCommand: remoteCommand)
    }

    var reconnectsInternally: Bool { true }
    var requiresPseudoTerminal: Bool { true }
}

/// Owns the per-endpoint ``RemoteTmuxSSHTransport`` instances ``RemoteTmuxController``
/// uses for SSH discovery, keyed by ``RemoteTmuxHost/connectionHash`` (destination +
/// port + identity).
///
/// Factored out of the controller so the get-or-create lifecycle and the scattered
/// dictionary bookkeeping live behind a small `@MainActor` surface. It only manages
/// the transport handles; it deliberately does NOT own the `ssh -O exit`
/// (``RemoteTmuxSSHTransport/spawnControlMasterExit(host:)``) teardown, which the
/// controller sequences around its own `await` gaps.
@MainActor
final class RemoteTmuxTransportRegistry {
    private var transports: [String: RemoteTmuxSSHTransport] = [:]

    /// Returns (creating if needed) the transport for a host.
    func transport(for host: RemoteTmuxHost) -> RemoteTmuxSSHTransport {
        if let existing = transports[host.connectionHash] {
            return existing
        }
        let transport = RemoteTmuxSSHTransport(host: host)
        transports[host.connectionHash] = transport
        return transport
    }

    /// Tears down a host's shared SSH master (used when removing a host).
    func disconnectMaster(host: RemoteTmuxHost) async {
        let transport = transports.removeValue(forKey: host.connectionHash)
        await transport?.shutdownMaster()
    }

    /// Whether a transport already exists for `connectionHash` (the reattach-reclaim check).
    func contains(connectionHash: String) -> Bool {
        transports[connectionHash] != nil
    }

    /// Removes and returns the transport for `connectionHash`, if any.
    @discardableResult
    func remove(connectionHash: String) -> RemoteTmuxSSHTransport? {
        transports.removeValue(forKey: connectionHash)
    }

    /// The hosts of every currently-tracked transport.
    func allHosts() -> [RemoteTmuxHost] {
        transports.values.map(\.host)
    }

    /// Drops every tracked transport (does not exit their masters).
    func removeAll() {
        transports.removeAll()
    }
}
