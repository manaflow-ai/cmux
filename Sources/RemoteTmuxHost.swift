import Foundation

/// Identifies a remote host whose tmux server cmux mirrors over SSH.
///
/// A host is addressed by its SSH `destination` — either a `~/.ssh/config`
/// alias (e.g. `claude-box`) or an explicit `user@host`. cmux multiplexes
/// every operation against the host (discovery commands, the `tmux -CC`
/// control client, and one-shot mutations) over a single SSH ControlMaster
/// socket derived from the destination, so authentication happens once.
struct RemoteTmuxHost: Sendable, Equatable, Codable, Identifiable {
    /// The SSH destination: a `~/.ssh/config` alias or `user@host`.
    let destination: String

    /// Optional explicit port (`-p`). `nil` defers to `~/.ssh/config`.
    let port: Int?

    /// Optional explicit identity file (`-i`). `nil` defers to `~/.ssh/config`.
    let identityFile: String?

    /// Stable identity for UI/persistence: the destination string.
    var id: String { destination }

    init(destination: String, port: Int? = nil, identityFile: String? = nil) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
    }

    /// A human-readable (but lossy) slug for the destination, used only for
    /// debuggability in the control socket filename. It lowercases and maps
    /// every non-alphanumeric character to `-`, so distinct destinations can
    /// collapse to the same slug — uniqueness comes from ``destinationHash``,
    /// never from the slug alone.
    var slug: String {
        let lowered = destination.lowercased()
        let mapped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        let collapsed = String(mapped.prefix(40))
        return collapsed.isEmpty ? "host" : collapsed
    }

    /// A stable, deterministic, collision-resistant hex digest of the exact,
    /// case-sensitive ``destination`` (FNV-1a/64). Two destinations that share a
    /// lossy ``slug`` (e.g. `alice@host` vs `alice.host`, or `Host` vs `host`)
    /// still get different digests, so they never share a ControlMaster socket.
    var destinationHash: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in destination.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV prime
        }
        return String(format: "%016llx", hash)
    }

    /// The SSH ControlMaster socket path shared by every operation against this host.
    ///
    /// Kept short (well under the AF_UNIX 104-byte limit) and namespaced under
    /// `~/.cmux/ssh/`. The filename combines the lossy human-readable ``slug``
    /// with the collision-resistant ``destinationHash`` of the exact
    /// destination, so two distinct destinations never collide on one socket
    /// (which would otherwise route commands — including the destructive
    /// `kill-session` — to the wrong host through a shared master).
    var controlSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cmux/ssh/tmux-\(slug)-\(destinationHash).sock"
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
    /// - Parameter controlPersistSeconds: how long the master lingers idle
    ///   after the last client detaches, so back-to-back commands stay fast.
    /// - Parameter batchMode: when `true`, ssh never prompts interactively
    ///   (correct for non-interactive discovery/mutation commands; the
    ///   `tmux -CC` control client runs under a PTY and must NOT set this).
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

    /// Single-quotes a value for safe interpolation into a `/bin/sh` command.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
            batchMode: false
        ))
        let quotedName = Self.shellSingleQuoted(sessionName)
        let remoteCommand = createIfMissing
            ? "tmux -CC new-session -A -s \(quotedName)"
            : "tmux -CC attach-session -t \(quotedName)"
        args.append(contentsOf: ["--", destination, remoteCommand])
        return args
    }
}
