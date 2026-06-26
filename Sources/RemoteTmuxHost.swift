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
    var slug: String {
        let lowered = destination.lowercased()
        let mapped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        let collapsed = String(mapped.prefix(40))
        return collapsed.isEmpty ? "host" : collapsed
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
    /// Kept short (well under the AF_UNIX 104-byte limit) and namespaced under
    /// `~/.cmux/ssh/`. The filename combines the lossy human-readable ``slug``
    /// with the collision-resistant ``connectionHash`` of the exact connection
    /// identity (destination + port + identity file), so two distinct endpoints
    /// never collide on one socket (which would otherwise route commands —
    /// including the destructive `kill-session` — to the wrong host through a
    /// shared master).
    var controlSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cmux/ssh/tmux-\(slug)-\(connectionHash).sock"
    }

    /// Ensures the directory that holds the control socket exists.
    func ensureControlSocketDirectory() throws {
        let dir = (controlSocketPath as NSString).deletingLastPathComponent
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
    /// `-f` makes ssh go to background **after authentication** (just before the
    /// remote `true`): the password / host-key / MFA prompt and any auth error
    /// ("Permission denied") still appear on the controlling tty first, and the
    /// CLI's foreground ssh exits promptly — but the persistent ControlMaster that
    /// `ControlPersist` leaves running then has its standard fds detached, so it no
    /// longer holds the terminal's pty open. Without `-f` the backgrounded master
    /// keeps the terminal's stdout/stderr, freezing window/app close until the
    /// master gives up (~`ServerAliveInterval`×`ServerAliveCountMax` seconds).
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
            + ["-o", "BatchMode=no", "-f", "-T", "--", destination, "true"]
    }

    /// The dictionary key for a control connection / session mirror, scoped to this
    /// host's full SSH connection identity (``connectionHash`` — destination + port
    /// + identity), so the same destination reached on a different port or with a
    /// different identity file never aliases onto another endpoint's connection.
    func connectionKey(sessionName: String) -> String {
        "\(connectionHash)\u{1}\(sessionName)"
    }

    /// Single-quotes a value for safe interpolation into a `/bin/sh` command.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

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
        let quotedName = Self.shellSingleQuoted(sessionName)
        let remoteCommand = createIfMissing
            ? "tmux -CC new-session -A -s \(quotedName)"
            : "tmux -CC attach-session -t \(quotedName)"
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
