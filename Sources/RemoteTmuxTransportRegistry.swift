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

    /// The port this transport actually uses, given a host's optional override.
    ///
    /// One place resolves the default so identity and argv cannot disagree: hashing an unset port
    /// separately from the explicit value it resolves to gave one host two controller keys.
    func resolvedTransportPort(_ configured: Int?) -> Int {
        switch self {
        case .ssh: return configured ?? 22
        case .et: return configured ?? 2022
        }
    }

    /// The profile that carries this transport.
    func profile(port: Int?, terminalPath: String? = nil) -> RemoteTmuxTransportProfile {
        switch self {
        case .ssh:
            return RemoteTmuxSSHTransportProfile()
        case .et:
            // etserver listens on 2022 by default, and a host's `port` means "the port of
            // this host's transport" — for et that is etserver's, not sshd's.
            // A terminal path has to be sent: `etterminal` is not on a non-interactive ssh PATH on
            // macOS, and without the flag et fails with "Error starting ET process through ssh".
            // Measured — dropping the flag entirely was worse than the literal it replaced.
            //
            // So it is resolved rather than assumed. `RemoteTmuxController` probes the host once
            // over the ssh one-shot channel and stores the answer; this default is only the
            // starting point for a host nobody has probed yet.
            return RemoteTmuxETTransportProfile(
                port: resolvedTransportPort(port),
                remoteTerminalPath: terminalPath ?? RemoteTmuxETTransportProfile.defaultRemoteTerminalPath
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
/// cmux's recovery is built on stdout EOF: the stream ends, so respawn with backoff.
///
/// The tempting rule is that a transport owning its own reconnection does not end for a network
/// drop, so its exit must mean the session ended. Measured against et 6.2.11+7, that is false:
/// restarting only `etserver` closes the stream while `tmux has-session` still succeeds. Acting on
/// it discarded mirrors whose sessions were alive and reattachable.
///
/// EOF cannot distinguish "the transport died" from "the session died", for any transport, so this
/// does not try. Reattaching answers the question: the reconnect path already classifies a genuinely
/// gone session from what the reattach reports. The failure such a transport still needs watching
/// for is the one EOF never reports at all — alive but wedged.
enum RemoteTmuxStreamEndDisposition: Sendable, Equatable {
    /// cmux owns recovery: respawn the transport with backoff.
    case reconnect
    /// The transport owned recovery, so its exit is terminal.
    case sessionOver

    /// What EOF on the control stream means.
    ///
    /// It used to branch on who owns reconnection, and that branch was wrong (see this type's
    /// documentation). The distinction that does hold is whether the stream ever worked:
    ///
    /// - reached control mode, then ended: something was there and may still be. Reconnect, and let
    ///   the reattach report whether the session is gone.
    /// - never reached control mode: the transport failed to *start*. There is no session behind it
    ///   to preserve, and retrying only hides the reason — measured, it turned "tmux control stream
    ///   ended before attach" into an opaque 60-second attach timeout.
    static func forStreamEnd(hasReachedControlMode: Bool) -> RemoteTmuxStreamEndDisposition {
        hasReachedControlMode ? .reconnect : .sessionOver
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
    /// Where `et` may live, in preference order. Apple Silicon Homebrew installs under
    /// `/opt/homebrew`, Intel under `/usr/local`, Linux under `/usr` — a single literal path is a
    /// claim about someone else's machine, and hardcoding `/usr/local/bin` made this transport
    /// unusable on a standard Apple Silicon install.
    static let clientSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Used when nothing is found, matching et's own documented install location.
    ///
    /// NOT the bare name `et`: the control stream is spawned through `/usr/bin/script`, which
    /// resolves its argument against the *app's* PATH, and a GUI app's PATH cannot be relied on.
    /// Measured — `script -q /dev/null et --version` under a minimal PATH reports
    /// `script: et: No such file or directory`, the stream ends immediately, and end-of-stream now
    /// means reconnect, so the failure surfaces as a 60-second attach timeout with no error rather
    /// than as "et not found".
    static let defaultClientPath = "/usr/local/bin/et"

    /// The first `et` that exists on PATH or in a known install directory.
    static func resolveClientExecutable(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathValue: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String {
        let fromPath = (pathValue ?? "").split(separator: ":").map(String.init)
        for directory in fromPath + clientSearchDirectories {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: trimmed).appendingPathComponent("et").path
            if fileExists(candidate) { return candidate }
        }
        return defaultClientPath
    }

    /// Longest line a remote login shell will accept, `MAX_CANON` on macOS.
    ///
    /// et types the command into a pty rather than exec'ing it, so this is a hard delivery limit
    /// and not a style guide: a longer line never completes, the shell runs nothing, and the attach
    /// dies on a timeout with nothing to explain it. Checked against real et in
    /// `scripts/remote-tmux-et-conformance.sh`, on both 6.2.11+7 and 7.0.0.
    static let maxCanonicalLineBytes = 1024

    /// Longest session name whose attach command still fits one canonical line.
    ///
    /// Derived from the command this profile actually builds rather than guessed, so it cannot
    /// drift away from it. tmux itself accepts names far longer than this — roughly 1000 bytes —
    /// which is why an unbounded name reached et and silently delivered nothing.
    static func maxSessionNameBytes(createIfMissing: Bool = false) -> Int {
        let overhead = controlStreamRemoteCommand(sessionName: "", createIfMissing: createIfMissing)
            .utf8.count
        return max(0, maxCanonicalLineBytes - overhead - 1)
    }

    /// Where `etterminal` is looked for on the remote, in preference order.
    ///
    /// Sent explicitly because a non-interactive ssh on macOS does not have it on PATH — which is
    /// also why `et` ships `--macserver` at all. The list exists so a host can be probed instead
    /// of assumed: Apple Silicon Homebrew, Intel Homebrew, then Linux packages.
    static let remoteTerminalCandidates = [
        "/opt/homebrew/bin/etterminal",
        "/usr/local/bin/etterminal",
        "/usr/bin/etterminal",
    ]

    /// Used until a host has been probed. Matches what `et --macserver` would send, so an
    /// unprobed host behaves as before rather than worse.
    static let defaultRemoteTerminalPath = "/usr/local/bin/etterminal"

    /// A shell command that prints the first candidate that exists on the remote.
    ///
    /// Short by construction: it is delivered the same way every other et command is, so it is
    /// subject to the same canonical-line limit.
    static func remoteTerminalProbeCommand() -> String {
        "command -v etterminal || " + remoteTerminalCandidates
            .map { "([ -x \($0) ] && echo \($0))" }
            .joined(separator: " || ")
    }

    /// etserver's default port is 2022, not ssh's 22.
    let port: Int
    /// `et` binary path.
    let executable: String
    /// Path to `etterminal` on the server, needed when it is not on the remote PATH — which
    /// is the case for a macOS server, where `--macserver` exists to set exactly this.
    let remoteTerminalPath: String?

    init(
        port: Int = 2022,
        executable: String? = nil,
        remoteTerminalPath: String? = nil
    ) {
        self.port = port
        self.executable = executable ?? Self.resolveClientExecutable()
        self.remoteTerminalPath = remoteTerminalPath
    }

    /// The remote command this profile runs, in one place so the length bound above is derived
    /// from the same string that is actually sent.
    static func controlStreamRemoteCommand(sessionName: String, createIfMissing: Bool) -> String {
        ([
            "tmux",
            "-CC",
            createIfMissing ? "new-session" : "attach-session",
            "-t", sessionName,
        ] as [String])
            .map(RemoteTmuxHost.shellSingleQuoted)
            .joined(separator: " ")
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
        let remote = Self.controlStreamRemoteCommand(
            sessionName: sessionName, createIfMissing: createIfMissing
        )
        // Arguments only: the executable is supplied separately (see ``executablePath()``),
        // exactly as the ssh profile does. Including it here would pass `et` twice.
        var argv = ["-p", String(port)]
        if let remoteTerminalPath {
            argv += ["--terminal-path", remoteTerminalPath]
        }
        // et bootstraps over ssh before its own protocol takes over, and it does not inherit the
        // host's ssh settings from anywhere. Passing them through `--ssh-option` is what makes
        // `--port 2222 --identity /key --transport et` reach the same sshd the ssh preflight just
        // used; without it the preflight succeeds and et's bootstrap fails against defaults.
        //
        // `host.port` is the SSH port here, distinct from `port` above, which is etserver's.
        if let sshPort = host.port {
            argv += ["--ssh-option", "Port=\(sshPort)"]
        }
        if let identityFile = host.identityFile {
            argv += ["--ssh-option", "IdentityFile=\(identityFile)"]
        }
        // `exec` so the login shell does not linger as a parent of tmux. `--` ends et's option
        // parsing for the same reason ssh's argv does: a destination beginning with `-` has to be a
        // host, never an option. Measured against et 6.2.11+7 - with the guard, `-weirdhost` is
        // reported as an unreachable host; without it, et swallows it and exits "Missing host to
        // connect to".
        argv += ["-c", "exec \(remote)", "--", host.destination]
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
