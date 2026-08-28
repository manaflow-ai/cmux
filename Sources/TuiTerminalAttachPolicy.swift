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
    ///
    /// `configPath` is required and must be non-empty: every bridge-spawned
    /// cmux-tui process is config-isolated, with no configless variant. App
    /// sessions must never parse the user's interactive
    /// `~/.config/cmux/cmux-tui.json`, whose schema belongs to a different
    /// binary version: parse warnings print onto the surface (a flash when
    /// the alt screen pops on quit), and a `machine_provider` block there
    /// puts the client in provider mode, which refuses `attach --session`
    /// outright, killing the tab at spawn. An earlier revision prefixed the
    /// config only on the reattach path, so brand-new tabs hit exactly that.
    /// (cmux-tui treats an EMPTY `CMUX_TUI_CONFIG` as unset and falls back
    /// to the user config, hence the non-empty requirement.)
    ///
    /// The prefix uses `env VAR=value <cmd>`, not a bare `VAR=value` prefix:
    /// Ghostty runs the surface command as `bash -c "exec -l <cmd>"`, and
    /// `exec` is a builtin, so a leading assignment is treated as the
    /// program name and the launch fails ("cannot execute: No such file or
    /// directory"). env(1) execs the real command with the variable set
    /// regardless of the exec-builtin wrapper.
    static func attachCommand(
        binaryPath: String,
        sessionName: String,
        terminalID: String,
        configPath: String
    ) -> String {
        assert(!configPath.isEmpty, "bridge attach commands must be config-isolated")
        let tokens: [String] = [
            "env", "CMUX_TUI_CONFIG=\(shellQuoted(configPath))",
            shellQuoted(binaryPath),
            "attach",
            "--session", shellQuoted(sessionName),
            "--terminal", shellQuoted(terminalID),
        ]
        return tokens.joined(separator: " ")
    }

    /// TERM for the daemon's child shells. The daemon is spawned by the app
    /// outside any terminal, so without an explicit override its children
    /// inherit whatever TERM the app process has (usually nothing useful);
    /// the surfaces rendering these terminals are always Ghostty.
    static let childShellTerm = "xterm-ghostty"

    /// The argument list that starts the app-managed daemon session.
    /// `--term` must follow `server start` (it is a start option) and makes
    /// child shells see the Ghostty terminfo instead of the
    /// xterm-256color default.
    static func daemonStartArguments(sessionName: String) -> [String] {
        [
            "server", "start",
            "--session", sessionName,
            "--headless",
            "--term", childShellTerm,
        ]
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

    /// Close-confirmation decision for one daemon-backed terminal tab, from
    /// the daemon's `terminal <id> process show --json` output. The local
    /// surface child is the always-running attach client, so the app's
    /// process-based heuristic would always prompt; the daemon's process
    /// tree is the real state.
    enum CloseConfirmationDecision: Equatable {
        /// A foreground process beyond the shell is running: prompt.
        case prompt
        /// Only the idle shell is running: close without prompting.
        case noPrompt
        /// The daemon could not be queried or the payload was unreadable:
        /// the caller must fall back to the existing prompt behavior.
        case unknown
    }

    /// Root executables that count as "just the shell". Anything else as the
    /// terminal's root process is itself a running command.
    private static let idleShellExecutableNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "pwsh",
    ]

    /// Decides prompt-vs-no-prompt from `process show` JSON
    /// (shape: `{"argv":[...],"children":[pid...],"executable":"/bin/zsh","pid":n}`).
    /// Mirrors the local heuristic as closely as the daemon data allows:
    /// prompt when the shell has any child process, or when the root process
    /// is not a shell at all. Missing or malformed data is `.unknown`, never
    /// a silent skip of the confirmation.
    static func closeConfirmationDecision(fromProcessShowJSON data: Data?) -> CloseConfirmationDecision {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let children = object["children"] as? [Any]
        else { return .unknown }
        if !children.isEmpty { return .prompt }
        guard let executable = object["executable"] as? String, !executable.isEmpty else {
            return .unknown
        }
        var name = (executable as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return idleShellExecutableNames.contains(name) ? .noPrompt : .prompt
    }

    /// The CLI argument list that reads one daemon terminal's process tree.
    static func processShowArguments(sessionName: String, terminalID: String) -> [String] {
        ["--session", sessionName, "--json", "terminal", terminalID, "process", "show"]
    }

    /// The CLI argument list that closes one daemon terminal, ending its
    /// session-owned process and removing all of its placements.
    static func terminalCloseArguments(sessionName: String, terminalID: String) -> [String] {
        ["--session", sessionName, "terminal", terminalID, "close"]
    }

    /// Whether tearing down one GUI panel should close its daemon terminal.
    /// Closing a tab (or its pane/workspace) ends the daemon terminal so it
    /// cannot be orphaned; a detach transfer keeps it (the surface moves to
    /// another container alive), and app termination keeps it too (quit owns
    /// the keep-vs-stop choice through its own dialog).
    static func shouldCloseDaemonTerminalOnPanelDiscard(
        closePanel: Bool,
        preservesTerminalForTransfer: Bool,
        isTerminatingApp: Bool
    ) -> Bool {
        closePanel && !preservesTerminalForTransfer && !isTerminatingApp
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

    /// Harbor: the CLI argument list that creates the shared empty daemon
    /// workspace Harbor attach terminals run in. `--empty` avoids spawning a
    /// default shell nobody attaches to.
    static func harborWorkspaceCreateArguments(sessionName: String) -> [String] {
        ["--session", sessionName, "--json", "workspace", "create", "--empty", "--name", harborWorkspaceName]
    }

    /// Harbor: the CLI argument list that runs one attach command as a new
    /// daemon terminal. `shell` routes the command through the daemon's
    /// default login shell so tool binaries resolve through the user's PATH.
    static func harborRunArguments(
        sessionName: String,
        workspaceSelector: String,
        terminalName: String,
        shellCommand: String
    ) -> [String] {
        [
            "--session", sessionName, "--json",
            "workspace", workspaceSelector, "run",
            "--name", terminalName,
            "shell", shellCommand,
        ]
    }

    static let harborWorkspaceName = "harbor"

    /// Extracts the created workspace id from `workspace create --json`
    /// output (shape: `{"value": {"workspace_id": "ws_..."}}`).
    static func workspaceID(fromWorkspaceCreateJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? [String: Any],
              let workspaceID = value["workspace_id"] as? String,
              !workspaceID.isEmpty
        else { return nil }
        return workspaceID
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
