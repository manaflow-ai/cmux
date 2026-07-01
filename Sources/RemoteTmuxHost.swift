import Foundation

/// Identifies a remote host whose tmux server cmux mirrors over SSH.
///
/// A host is addressed by its SSH `destination` — either a `~/.ssh/config`
/// alias (e.g. `claude-box`) or an explicit `user@host`. cmux multiplexes
/// every operation against the host (discovery commands, the `tmux -CC`
/// control client, and one-shot mutations) over a single SSH ControlMaster
/// socket derived from the destination, so authentication happens once.
struct RemoteTmuxHost: Sendable, Equatable, Identifiable {
    /// The SSH destination: a `~/.ssh/config` alias or `user@host`.
    let destination: String

    /// Optional explicit port (`-p`). `nil` defers to `~/.ssh/config`.
    let port: Int?

    /// Optional explicit identity file (`-i`). `nil` defers to `~/.ssh/config`.
    let identityFile: String?

    /// Stable identity matching the connection-uniqueness key. Two hosts with the
    /// same destination but a different port/identity are distinct endpoints (see
    /// ``connectionHash``), so `id` uses ``connectionHash`` rather than the
    /// destination alone — keeping ``Identifiable`` identity consistent with how
    /// ``RemoteTmuxController`` keys its per-endpoint state.
    var id: String { connectionHash }

    init(destination: String, port: Int? = nil, identityFile: String? = nil) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
    }

    /// A human-readable (but lossy) slug for the destination, used only for
    /// debuggability in the control socket filename. It lowercases and maps
    /// every non-alphanumeric character to `-`, so distinct destinations can
    /// collapse to the same slug — uniqueness comes from ``connectionHash``,
    /// never from the slug alone.
    ///
    /// The slug is *not* length-capped here: ``controlSocketPath`` trims it to
    /// whatever budget remains after the fixed parts of the path, so the socket
    /// (plus OpenSSH's transient bind suffix) always fits the AF_UNIX limit.
    var slug: String {
        let lowered = destination.lowercased()
        let mapped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        return mapped.isEmpty ? "host" : String(mapped)
    }

    /// A stable, deterministic, collision-resistant hex digest of this host's full
    /// **connection identity** — the case-sensitive ``destination`` plus the
    /// explicit ``port`` and ``identityFile`` — over a unit-separated fingerprint
    /// (FNV-1a/64).
    ///
    /// Two hosts that share a lossy ``slug`` (e.g. `alice@host` vs `alice.host`),
    /// *or* the same destination reached on a different port or with a different
    /// identity file, get different digests — so they never share a ControlMaster
    /// socket. That separation is a safety property, not just hygiene: the master
    /// multiplexes destructive commands (`kill-session`, `rename-window`), so two
    /// distinct endpoints must never collapse onto one socket and risk routing a
    /// command to the wrong server.
    var connectionHash: String {
        let fingerprint = "\(destination)\u{1f}\(port.map(String.init) ?? "")\u{1f}\(identityFile ?? "")"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in fingerprint.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV prime
        }
        return String(format: "%016llx", hash)
    }

    /// The SSH ControlMaster socket path shared by every operation against this host.
    ///
    /// Namespaced under `~/.cmux/ssh/`. The filename combines the lossy
    /// human-readable ``slug`` with the collision-resistant ``connectionHash`` of
    /// the exact connection identity (destination + port + identity file), so two
    /// distinct endpoints never collide on one socket (which would otherwise route
    /// commands — including the destructive `kill-session` — to the wrong host
    /// through a shared master).
    ///
    /// The slug is trimmed so the final path *plus OpenSSH's transient bind
    /// suffix* stays within the AF_UNIX limit. OpenSSH never binds `ControlPath`
    /// directly: it binds `<ControlPath>.XXXXXXXXXXXXXXXX` (a 17-byte suffix) and
    /// atomically renames it into place, so the socket path budget must account
    /// for that suffix — otherwise long destinations fail with
    /// `unix_listener: path "…" too long for Unix domain socket`. The
    /// ``connectionHash`` is never trimmed, so uniqueness is preserved even when
    /// the slug is dropped entirely. ``ensureControlSocketDirectory()`` rejects
    /// the rare case where even an empty slug overflows (an unusually long home).
    var controlSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Fixed parts that can never be trimmed: directory, the `tmux-` prefix,
        // the `-<hash>.sock` tail, and the transient suffix OpenSSH binds first.
        let prefix = "\(home)/.cmux/ssh/tmux-"
        let suffix = "-\(connectionHash).sock"
        let fixedBytes = prefix.utf8.count + suffix.utf8.count + Self.opensshTransientSuffixLength
        let slugBudget = max(0, Self.maxUnixSocketPathLength - fixedBytes)
        return "\(prefix)\(Self.trimmedToUTF8ByteBudget(slug, slugBudget))\(suffix)"
    }

    /// macOS caps an AF_UNIX `sun_path` at 104 bytes (including the NUL
    /// terminator), so the usable path length is 103 bytes.
    private static let maxUnixSocketPathLength = 103

    /// Bytes OpenSSH appends to `ControlPath` for its transient pre-rename bind
    /// socket: a `.` plus 16 random characters (see `mux.c`). The bound path must
    /// fit the AF_UNIX limit, not just the final renamed `ControlPath`.
    private static let opensshTransientSuffixLength = 17

    /// Whether the path OpenSSH would actually bind for `controlPath` — i.e.
    /// `controlPath` plus its 17-byte transient suffix — fits the AF_UNIX limit.
    /// ``ensureControlSocketDirectory()`` checks this before opening the master so
    /// an un-bindable path fails with a clear error instead of the opaque
    /// `unix_listener: … too long`.
    static func controlSocketPathFitsUnixLimit(_ controlPath: String) -> Bool {
        controlPath.utf8.count + opensshTransientSuffixLength <= maxUnixSocketPathLength
    }

    /// Returns the longest whole-`Character` prefix of `value` whose UTF-8
    /// encoding fits `byteBudget`. Trims on Character (not byte) boundaries so a
    /// multi-byte scalar is never split, and counts bytes (not characters)
    /// because the AF_UNIX limit is measured in bytes.
    private static func trimmedToUTF8ByteBudget(_ value: String, _ byteBudget: Int) -> String {
        guard value.utf8.count > byteBudget else { return value }
        var result = ""
        var used = 0
        for ch in value {
            let chBytes = String(ch).utf8.count
            if used + chBytes > byteBudget { break }
            result.append(ch)
            used += chBytes
        }
        return result
    }

    /// Ensures the directory that holds the control socket exists.
    ///
    /// Also rejects up front the rare case where the home directory is long
    /// enough that the fixed path parts alone overflow the AF_UNIX limit, so even
    /// an empty slug can't fit (``controlSocketPath`` trims the slug but cannot
    /// shrink the home dir / hash / suffix). Without this guard `ssh` would still
    /// open, then die with the opaque `unix_listener: … too long` — surfacing it
    /// here gives a clear, actionable error instead.
    func ensureControlSocketDirectory() throws {
        let path = controlSocketPath
        guard Self.controlSocketPathFitsUnixLimit(path) else {
            let boundPathBytes = path.utf8.count + Self.opensshTransientSuffixLength
            let message = String(
                format: String(
                    localized: "remoteTmux.error.controlSocketPathTooLong",
                    defaultValue: "SSH control socket path is too long for a Unix domain socket (%lld > %lld bytes); home directory path is too long"
                ),
                boundPathBytes,
                Self.maxUnixSocketPathLength
            )
            throw RemoteTmuxError.unreachable(message)
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// SSH options that reuse (or open) the shared ControlMaster.
    ///
    /// Deliberately does NOT pin `StrictHostKeyChecking`, so ssh honors the
    /// user's `~/.ssh/config` host-key policy. Under `batchMode` an unknown host
    /// key therefore fails fast ("Host key verification failed") instead of being
    /// silently trusted; ``RemoteTmuxController`` classifies that as needing
    /// interactive auth and routes the user to ``interactiveAuthInvocation()``
    /// (which likewise does not pin `StrictHostKeyChecking`, so ssh's default
    /// `ask` prompts) to confirm the fingerprint in their terminal — the native
    /// SSH first-contact experience.
    ///
    /// - Parameter controlPersistSeconds: how long the master lingers idle
    ///   after the last client detaches, so back-to-back commands stay fast.
    /// - Parameter batchMode: when `true`, ssh never prompts interactively.
    ///   Use this for discovery/mutation commands and for the pipe-backed local
    ///   `tmux -CC` control client; interactive prompts are handled only by
    ///   ``interactiveAuthInvocation()`` running in the user's terminal.
    func sshControlArguments(controlPersistSeconds: Int, batchMode: Bool) -> [String] {
        var args = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ControlPersist=\(controlPersistSeconds)",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=3",
        ]
        if batchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if let port {
            args.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile, !identityFile.isEmpty {
            args.append(contentsOf: ["-i", identityFile])
        }
        return args
    }

    /// Builds the full `ssh` argv (executable first) for a one-shot **interactive**
    /// authentication that opens the shared ControlMaster, then exits.
    ///
    /// Runs `ssh <control opts, no BatchMode> -T -- <destination> true`: it
    /// authenticates against the host (password / host-key TOFU /
    /// keyboard-interactive MFA / FIDO touch all prompt on the controlling tty),
    /// runs the trivial remote `true`, and exits — leaving the master alive for
    /// ``controlPersistSeconds`` so the subsequent pipe-based discovery and
    /// `tmux -CC` control client multiplex over it with no further prompt.
    ///
    /// Intended to be run by the `cmux ssh-tmux` CLI **inside the user's terminal**
    /// (which supplies the tty); the local control client itself uses plain pipes
    /// and cannot prompt. It forces `BatchMode=no` so the interactive prompt always
    /// works even when the user's ssh_config sets `BatchMode yes`, but it does NOT
    /// pin `StrictHostKeyChecking`: the user's host-key policy is honored (a
    /// configured `StrictHostKeyChecking=yes` must not be silently downgraded to a
    /// TOFU prompt), and ssh's default `ask` already prompts to confirm a new
    /// fingerprint on this controlling tty.
    ///
    /// Critically, this opens the master in the **foreground** (no `-f`): ssh
    /// authenticates, opens the master, runs the remote `true`, and exits only once
    /// the control socket has served that session. So by the time the CLI's
    /// foreground ssh returns, the master is provably *serving* — the post-auth
    /// retry rides it deterministically, with no `ssh -O check` readiness poll.
    ///
    /// `-f` (background-after-auth) is deliberately NOT used: it returns before the
    /// backgrounded master binds its control socket, racing the immediate retry. The
    /// historical worry that a foreground master would keep the terminal's
    /// stdout/stderr and freeze window/app close does not apply: when `ControlPersist`
    /// backgrounds the master, OpenSSH's `control_persist_detach()` redirects the
    /// master's std fds to `/dev/null` (`stdfd_devnull(1, 1, …)` in `ssh.c`, identical
    /// across OpenSSH 9.6/9.8/9.9/10.2 — the versions macOS 14/15/26 ship), and forces
    /// that detach independent of `-f`. So the foreground ssh exits cleanly and the
    /// detached master never pins the tty.
    ///
    /// `-n` is kept explicitly: `-f` *implied* `-n` (stdin from `/dev/null`), and
    /// dropping `-f` would otherwise leave the controlling terminal as the remote
    /// command's stdin. With the trivial `true` that's usually harmless, but a host
    /// `ForceCommand` / forced wrapper, or noninteractive shell startup that reads
    /// stdin, could consume the user's terminal input or block. `-n` preserves the
    /// stdin-null behavior without backgrounding; auth prompts are unaffected (ssh
    /// reads them from the controlling tty, not stdin).
    ///
    /// - Parameter sshExecutablePath: the local `ssh` binary the CLI will exec.
    /// - Parameter controlPersistSeconds: idle lifetime of the opened master.
    /// - Returns: argv where element 0 is `sshExecutablePath`; the `--`
    ///   end-of-options guard precedes the destination so a dash-prefixed
    ///   destination can never be parsed as an ssh option.
    func interactiveAuthInvocation(
        sshExecutablePath: String = "/usr/bin/ssh",
        controlPersistSeconds: Int = 180
    ) -> [String] {
        [sshExecutablePath]
            + sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: false)
            + ["-o", "BatchMode=no", "-n", "-T", "--", destination, "true"]
    }

    /// Single-quotes a value for safe interpolation into a `/bin/sh` command.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds a remote shell command that resolves `tmux` before executing it.
    ///
    /// OpenSSH runs remote commands under the account's shell, but not as an
    /// interactive/login shell. On macOS that often means zsh starts with only
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew's `tmux` is invisible even
    /// though it works in the user's normal terminal. Resolve the binary in a
    /// tiny `/bin/sh` wrapper, then `exec` it with the original arguments so both
    /// one-shot probes and `tmux -CC` use the same path behavior.
    static func tmuxRemoteCommand(arguments: [String]) -> String {
        (["/bin/sh", "-c", tmuxResolverShellScript, "cmux-remote-tmux"] + arguments)
            .map(shellSingleQuoted)
            .joined(separator: " ")
    }

    // Keep this one physical line: the remote login shell parses it before /bin/sh -c runs.
    private static let tmuxResolverShellScript =
        "cmux_tmux=\"\"; " +
        "if command -v tmux >/dev/null 2>&1; then cmux_tmux=\"$(command -v tmux)\"; else " +
        "for cmux_dir in \"$HOME/.local/bin\" \"$HOME/bin\" /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /snap/bin /usr/bin /bin; do " +
        "if [ -x \"$cmux_dir/tmux\" ]; then cmux_tmux=\"$cmux_dir/tmux\"; break; fi; done; " +
        "if [ -z \"$cmux_tmux\" ] && [ -x /usr/libexec/path_helper ]; then eval \"$(/usr/libexec/path_helper -s 2>/dev/null)\"; " +
        "if command -v tmux >/dev/null 2>&1; then cmux_tmux=\"$(command -v tmux)\"; fi; fi; fi; " +
        "if [ -n \"$cmux_tmux\" ]; then exec \"$cmux_tmux\" \"$@\"; fi; exec tmux \"$@\""

    /// Returns a non-empty tmux control-mode command argument, or `nil` when the
    /// value could break the line-oriented control stream. Shell quoting is not
    /// enough here: CR/LF/control bytes can terminate a `rename-*` command line
    /// before tmux parses the quoted argument.
    static func controlModeCommandName(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return controlModeLineSafeName(trimmed)
    }

    /// Validates a name already received from tmux. Unlike
    /// ``controlModeCommandName(_:)``, this preserves surrounding spaces because
    /// tmux is the source of truth for confirmed session/window names.
    static func controlModeLineSafeName(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        return value
    }

    /// Builds the `ssh` argv (for direct `Process` execution, no shell) that
    /// runs `tmux -CC` control mode for `sessionName` on this host.
    ///
    /// Uses `ssh -tt` to force a remote PTY (the remote `tmux attach` needs a
    /// tty); the local side is plain pipes. The remote command is one argument
    /// that the remote login shell parses, so the session name is single-quoted.
    /// A `--` end-of-options marker precedes the destination so a destination
    /// that begins with `-` can never be parsed by `ssh` as an option (which
    /// would allow `-oProxyCommand=…` local command injection).
    ///
    /// - Parameters:
    ///   - sessionName: the tmux session to attach to (or create).
    ///   - createIfMissing: `new-session -A -s` (attach or create) vs `attach-session -t`.
    func controlModeArguments(
        sessionName: String,
        createIfMissing: Bool,
        controlPersistSeconds: Int = 180
    ) -> [String] {
        var args = ["-tt"]
        args.append(contentsOf: sshControlArguments(
            controlPersistSeconds: controlPersistSeconds,
            batchMode: true
        ))
        let remoteCommand = Self.tmuxRemoteCommand(arguments: createIfMissing
            ? ["-CC", "new-session", "-A", "-s", sessionName]
            : ["-CC", "attach-session", "-t", sessionName])
        args.append(contentsOf: ["--", destination, remoteCommand])
        return args
    }

    /// Builds a ``DetectedSSHSession`` that uploads files to this host over SSH,
    /// reusing the same ControlMaster socket the control connection already opened
    /// (so an `scp` multiplexes over the existing authenticated master — no second
    /// prompt while a mirror is live).
    ///
    /// Used by the image-paste path: a screenshot pasted into a mirrored remote
    /// tmux pane is uploaded to the host and the remote path is inserted, so a
    /// remote CLI (e.g. claude) can read it — instead of inserting a macOS-local
    /// path that doesn't exist on the remote.
    func detectedSSHSession() -> DetectedSSHSession {
        DetectedSSHSession(
            destination: destination,
            port: port,
            identityFile: identityFile,
            configFile: nil,
            jumpHost: nil,
            controlPath: controlSocketPath,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
    }
}
