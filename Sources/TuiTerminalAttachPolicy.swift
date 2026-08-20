import Foundation

/// Pure decision logic for the cmux-tui terminal-backend spike (tier A of the
/// GUI-frontend migration plan). This is a throwaway bridge: when the beta
/// flag is on, a new main-grid terminal is backed by a cmux-tui daemon
/// terminal and the Ghostty surface runs `cmux-tui attach --terminal <id>`
/// instead of the shell, so the shell survives quitting the app. All I/O
/// (daemon spawn, CLI calls) lives in `TuiTerminalAttachBridge`; everything
/// here is deterministic and unit-testable.
enum TuiTerminalAttachPolicy {
    /// What session restore should do with a persisted daemon terminal id.
    enum RestoreDecision: Equatable {
        /// The daemon is alive and still owns the terminal: run the attach
        /// command instead of spawning a fresh shell, and skip scrollback
        /// replay (the daemon redraws its own scrollback).
        case reattach(terminalID: String)
        /// Fall back to today's fresh spawn path.
        case freshSpawn
    }

    /// Decides reattach-vs-fresh-spawn for one restored terminal panel.
    ///
    /// Reattach requires every link in the chain: the flag is on, the panel
    /// is a plain local terminal (remote workspaces and remote PTY sessions
    /// are out of scope), a terminal id was persisted, the daemon socket is
    /// alive, and the daemon still lists that id. Any missing link falls
    /// back to a fresh spawn.
    static func restoreDecision(
        flagEnabled: Bool,
        snapshotTerminalID: String?,
        isRemoteTerminal: Bool,
        hasRemotePTYSessionID: Bool,
        daemonSocketAlive: Bool,
        daemonTerminalIDs: Set<String>?
    ) -> RestoreDecision {
        guard flagEnabled,
              !isRemoteTerminal,
              !hasRemotePTYSessionID,
              let terminalID = snapshotTerminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !terminalID.isEmpty,
              daemonSocketAlive,
              let daemonTerminalIDs,
              daemonTerminalIDs.contains(terminalID)
        else {
            return .freshSpawn
        }
        return .reattach(terminalID: terminalID)
    }

    /// Whether a brand-new terminal surface should be provisioned in the
    /// daemon. Only plain local main-grid terminals qualify: an explicit
    /// startup command (agent launch, remote workspace bootstrap), a tmux
    /// start command, or a remote PTY session all keep today's path.
    static func shouldProvisionNewTerminal(
        flagEnabled: Bool,
        hasExplicitStartupCommand: Bool,
        hasTmuxStartCommand: Bool,
        hasRemotePTYSessionID: Bool,
        isRemoteWorkspace: Bool
    ) -> Bool {
        flagEnabled
            && !hasExplicitStartupCommand
            && !hasTmuxStartCommand
            && !hasRemotePTYSessionID
            && !isRemoteWorkspace
    }

    /// The daemon session name for this app instance: `cmux-<tag>` derived
    /// from the control socket path (`/tmp/cmux-debug-<tag>.sock`). The
    /// untagged sockets map to a stable per-variant name so a dev build never
    /// shares a daemon with the user's main app.
    static func sessionName(controlSocketPath: String) -> String {
        let base = (controlSocketPath as NSString).lastPathComponent
        let stem = base.hasSuffix(".sock") ? String(base.dropLast(".sock".count)) : base
        let prefixes = ["cmux-debug-", "cmux-nightly-", "cmux-staging-", "cmux-"]
        for prefix in prefixes where stem.hasPrefix(prefix) && stem.count > prefix.count {
            return "cmux-\(sanitizedSessionToken(String(stem.dropFirst(prefix.count))))"
        }
        return "cmux-\(sanitizedSessionToken(stem))"
    }

    /// cmux-tui's local socket path convention: `$TMPDIR/cmux-tui-<uid>/<session>.sock`.
    static func daemonSocketPath(
        sessionName: String,
        temporaryDirectory: String,
        uid: uid_t
    ) -> String {
        let dir = (temporaryDirectory as NSString).appendingPathComponent("cmux-tui-\(uid)")
        return (dir as NSString).appendingPathComponent("\(sessionName).sock")
    }

    /// The Ghostty surface command that replaces the shell: attach to exactly
    /// one daemon terminal. Tokens are single-quoted for the shell.
    static func attachCommand(
        binaryPath: String,
        sessionName: String,
        terminalID: String
    ) -> String {
        [
            shellQuoted(binaryPath),
            "attach",
            "--session", shellQuoted(sessionName),
            "--terminal", shellQuoted(terminalID),
        ].joined(separator: " ")
    }

    /// Extracts the created terminal id from `workspace create --json` output
    /// (shape: `{"value": {"terminal_id": "term_..."}}`).
    static func terminalID(fromWorkspaceCreateJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? [String: Any],
              let terminalID = value["terminal_id"] as? String,
              !terminalID.isEmpty
        else { return nil }
        return terminalID
    }

    /// Extracts the live terminal ids from `terminal list --json` output
    /// (shape: `[{"id": "term_...", ...}]`).
    static func terminalIDs(fromTerminalListJSON data: Data) -> Set<String>? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return Set(array.compactMap { $0["id"] as? String })
    }

    /// Whether quitting the app should first ask keep-vs-stop for the daemon
    /// session. Prompt only when the flag is on, no quit confirmation has
    /// already been given in this terminate flow (a second dialog on one quit
    /// is never acceptable), the daemon socket is alive, and it owns at least
    /// one live terminal. Every other case quits normally.
    static func shouldPromptToKeepDaemonSessionsOnQuit(
        flagEnabled: Bool,
        quitAlreadyConfirmed: Bool,
        daemonSocketAlive: Bool,
        liveTerminalIDs: Set<String>?
    ) -> Bool {
        guard flagEnabled,
              !quitAlreadyConfirmed,
              daemonSocketAlive,
              let liveTerminalIDs,
              !liveTerminalIDs.isEmpty
        else { return false }
        return true
    }

    /// The CLI argument lists that truly stop a daemon session, in order.
    /// `server stop` alone does NOT end PTY hosts (they stay adoptable and a
    /// later daemon re-adopts them), so every terminal is closed first, which
    /// ends the session-owned shell process, and only then is the server
    /// stopped.
    static func sessionStopCommands(
        sessionName: String,
        terminalIDs: [String]
    ) -> [[String]] {
        terminalIDs.map { ["--session", sessionName, "terminal", $0, "close"] }
            + [["server", "stop", "--session", sessionName]]
    }

    private static func sanitizedSessionToken(_ raw: String) -> String {
        let token = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return token.isEmpty ? "default" : token
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
