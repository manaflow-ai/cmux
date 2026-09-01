import Foundation

/// Pure decision logic for the cmux-tui terminal-backend spike (tier A of the
/// GUI-frontend migration plan). This is a throwaway bridge: when the beta
/// flag is on, a new main-grid terminal is backed by a cmux-tui daemon
/// terminal and the Ghostty surface runs `cmux-tui attach --terminal <id>`
/// instead of the shell, so the shell survives quitting the app. All I/O
/// (daemon spawn, CLI calls) lives in `TuiTerminalAttachBridge`; everything
/// here is deterministic and unit-testable.
enum TuiTerminalAttachPolicy {
    /// Chooses the renderer transport for a terminal that may have been
    /// provisioned by cmux-tui. A persisted terminal id is only a durable
    /// identity. It is not proof that the currently selected client can run
    /// the pipe-IO protocol. Keeping this decision pure prevents restore and
    /// split paths from drifting when an app update replaces the bundled
    /// binary.
    enum ManualIOAttachment: Equatable {
        /// Use the existing process-owned PTY path.
        case unavailable
        /// Mount a manual surface now, then bind its pump when provisioning
        /// commits. No terminal identity is fabricated for this state.
        case pending
        /// Mount a manual surface already bound to one durable terminal.
        case ready(terminalID: String)

        var terminalID: String? {
            guard case let .ready(terminalID) = self else { return nil }
            return terminalID
        }

        var usesManualSurface: Bool {
            switch self {
            case .unavailable: return false
            case .pending, .ready: return true
            }
        }
    }

    static func manualIOAttachment(
        requestedReattachTerminalID: String?,
        provisionedTerminalID: String?,
        provisioningPending: Bool,
        manualIOAvailable: Bool
    ) -> ManualIOAttachment {
        // A pending lease is an explicit creation transaction. Its capability
        // check runs inside that transaction, so an asynchronous probe must
        // not make the caller silently choose the legacy PTY path for this
        // surface. The old behavior made the first terminal depend on probe
        // timing and left later lifecycle code with two possible owners.
        if provisioningPending { return .pending }
        guard manualIOAvailable else { return .unavailable }
        if let terminalID = normalizedTerminalIdentifier(requestedReattachTerminalID) {
            return .ready(terminalID: terminalID)
        }
        if provisioningPending {
            return .pending
        }
        if let terminalID = normalizedTerminalIdentifier(provisionedTerminalID) {
            return .ready(terminalID: terminalID)
        }
        return .unavailable
    }

    private static func normalizedTerminalIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

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
    /// daemon. Only plain local terminals with no startup payload qualify.
    /// Commands, initial input, restore agents, remote PTY sessions, and
    /// remote workspaces keep the existing PTY path until the daemon launch
    /// contract can carry that state faithfully.
    static func shouldProvisionNewTerminal(
        flagEnabled: Bool,
        hasExplicitStartupCommand: Bool,
        hasTmuxStartCommand: Bool,
        hasRemotePTYSessionID: Bool,
        isRemoteWorkspace: Bool,
        hasStartupInput: Bool = false,
        hasStartupRestoreAgent: Bool = false,
        hasConfigCommand: Bool = false,
        hasConfigInitialInput: Bool = false
    ) -> Bool {
        flagEnabled
            && !hasExplicitStartupCommand
            && !hasTmuxStartCommand
            && !hasRemotePTYSessionID
            && !isRemoteWorkspace
            && !hasStartupInput
            && !hasStartupRestoreAgent
            && !hasConfigCommand
            && !hasConfigInitialInput
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
    static func daemonStartArguments(
        sessionName: String,
        socketPath: String? = nil
    ) -> [String] {
        var arguments = [
            "server", "start",
            "--session", sessionName,
            "--headless",
            "--term", childShellTerm,
        ]
        if let socketPath, !socketPath.isEmpty {
            arguments += ["--socket", socketPath]
        }
        return arguments
    }

    /// The canonical durable-owner lifecycle command. `server ensure` owns
    /// the spawn lock, detached process, socket bind, and readiness identity;
    /// the app must use this transaction instead of recreating those rules
    /// around a foreground `server start` process.
    static func daemonEnsureArguments(
        sessionName: String,
        socketPath: String
    ) -> [String] {
        [
            "--json",
            "--session", sessionName,
            "--socket", socketPath,
            "server", "ensure",
        ]
    }

    enum DaemonEnsureResult: Equatable {
        /// The client accepted the ensure request and returned a validated
        /// ready-owner response.
        case ready
        /// The selected client predates `server ensure`; callers may use the
        /// explicitly bounded legacy start path for compatibility.
        case unsupported
        /// The command exists but its response or execution was invalid. A
        /// real lifecycle error must not be hidden by a second spawn attempt.
        case failed
    }

    /// Classifies one `server ensure --json` result without interpreting human
    /// help text as a successful lifecycle transaction. The success payload
    /// is intentionally checked for the owner identity fields the canonical
    /// command promises, so a stale or mismatched binary fails closed.
    static func classifyDaemonEnsureResult(
        exitStatus: Int32?,
        timedOut: Bool,
        executionError: String?,
        stdout: String?,
        stderr: String?,
        expectedSession: String,
        expectedSocket: String
    ) -> DaemonEnsureResult {
        guard executionError == nil, !timedOut else { return .failed }
        let text = [stdout, stderr]
            .compactMap { $0 }
            .joined(separator: "\n")
        if let data = stdout?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if exitStatus == 0,
               let status = object["status"] as? String,
               status == "running" || status == "started",
               object["session"] as? String == expectedSession,
               object["socket"] as? String == expectedSocket,
               let pid = object["pid"] as? NSNumber,
               pid.int64Value > 0,
               let generation = object["generation"] as? String,
               !generation.isEmpty {
                return .ready
            }
            // Older clients report an unsupported action as a structured
            // usage error. Any other structured error belongs to the current
            // lifecycle contract and must remain visible to the caller.
            if object["code"] as? String == "usage.invalid",
               (object["message"] as? String)?.contains("unknown server action") == true {
                return .unsupported
            }
            return .failed
        }
        if exitStatus != 0,
           text.localizedCaseInsensitiveContains("unknown server action") {
            return .unsupported
        }
        return .failed
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

    /// Returns whether a cmux-tui client advertises the renderer-less relay.
    /// The app bundles a rolling client artifact, so its version can lag the
    /// source branch that enables this beta path. A missing or malformed help
    /// response is treated as unsupported and callers keep the existing PTY
    /// attach path.
    static func supportsPipeIO(fromHelpOutput data: Data?) -> Bool {
        guard let data else { return false }
        return String(decoding: data, as: UTF8.self).contains("--pipe-io")
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
