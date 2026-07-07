import Foundation

extension RemoteTmuxController {
    /// Returns the interactive SSH argv when an attach preflight failed because
    /// BatchMode could not prompt; otherwise the caller can handle the command
    /// result normally.
    nonisolated static func authRequiredAttachArgv(
        host: RemoteTmuxHost,
        result: RemoteTmuxCommandResult
    ) -> [String]? {
        guard !result.succeeded,
              RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(result.stderr) else {
            return nil
        }
        return host.interactiveAuthInvocation()
    }

    /// Returns a cwd only when its source panel is backed by a live tmux window.
    ///
    /// A mirror workspace can briefly contain a local bootstrap/default terminal
    /// before the first remote topology rebuild replaces it. That panel may have
    /// a local cwd, but sending it as `new-window -c` to the remote host would be
    /// wrong, so unresolved panels omit `-c`.
    nonisolated static func liveMirrorWindowWorkingDirectory(
        _ workingDirectory: String?,
        sourcePanelId: UUID?,
        windowIdForPanel: (UUID) -> Int?
    ) -> String? {
        guard let workingDirectory,
              let sourcePanelId,
              windowIdForPanel(sourcePanelId) != nil else { return nil }
        return workingDirectory
    }

    /// Builds the tmux `new-window` command for a mirror new-tab. Pure (testable).
    ///
    /// Placement (`afterWindowId`):
    /// - nil -> `new-window -a -t '{end}'`: `-a` inserts *after* the target and
    ///   `'{end}'` resolves to the highest-indexed window, so the new window lands
    ///   at the very end regardless of index gaps or which window tmux considers
    ///   current. (`'{end}'` is an alias for `$`, available since tmux 2.1.) Plain
    ///   `new-window` instead fills the lowest free index, landing mid-list when
    ///   the session has gaps from closed windows.
    /// - id -> `new-window -a -t @id`: insert right after that window. cmux never
    ///   `select-window`s the remote, so the selected tab's window is targeted by
    ///   id rather than relying on tmux's current window.
    ///
    /// Working directory: when non-blank, appends `-c '<path>'` so the new tab
    /// opens in the active tab's directory (like a local new tab). Without `-c`,
    /// tmux uses its default-path. The path is single-quoted so spaces and shell
    /// metacharacters survive tmux's parser (the quoting the `rename-*` commands
    /// use on this stream); a path carrying CR/LF/control bytes that could
    /// terminate the command line is dropped, leaving the placement-only command.
    nonisolated static func newWindowCommand(afterWindowId: Int?, workingDirectory: String?) -> String {
        var command = afterWindowId.map { "new-window -a -t @\($0)" } ?? "new-window -a -t '{end}'"
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty,
           RemoteTmuxHost.controlModeLineSafeName(directory) != nil {
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(directory))"
        }
        return command
    }

    /// The tab manager `remote.tmux.mirror` should mirror into: the host's
    /// dedicated mirror window when one is bound and still resolvable, else the
    /// fallback (usually the key window).
    static func mirrorTargetTabManager(
        dedicatedWindowId: UUID?,
        tabManagerForWindow: (UUID) -> TabManager?,
        fallbackTabManager: () -> TabManager?
    ) -> TabManager? {
        if let dedicatedWindowId, let manager = tabManagerForWindow(dedicatedWindowId) {
            return manager
        }
        return fallbackTabManager()
    }

    /// Parses tmux's stable session id (`"$3"`) to its numeric id.
    ///
    /// Only non-negative, `$`-prefixed ASCII decimal ids are accepted; names and
    /// malformed ids fall back to name-based matching by returning nil.
    nonisolated static func tmuxSessionNumericId(_ rawId: String) -> Int? {
        guard rawId.first == "$" else { return nil }
        let digits = rawId.dropFirst()
        guard !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return nil
        }
        return Int(String(digits))
    }

    /// Sessions not yet mirrored, using stable tmux ids before mutable names.
    ///
    /// Identity per session: a parsed stable id matching a mirrored connection's
    /// sessionId means already mirrored (so a rename whose `%session-renamed` has
    /// not re-keyed the mirror yet can never mirror the same session twice);
    /// otherwise the mutable name decides. A NEW session that reuses a mirrored
    /// session's stale pre-rename name therefore stays undiscovered until the
    /// rename event re-keys the mirror — deliberate: the whole attach pipeline
    /// (`connectionKey`, `mirrorSession`, `tmux attach -t`) keys sessions by
    /// name, so surfacing it here would only be dropped by those layers.
    /// Attaching by stable id end to end is follow-up territory.
    nonisolated static func unmirroredSessions(
        _ sessions: [RemoteTmuxSession],
        mirroredSessionIds: Set<Int>,
        mirroredNames: Set<String>
    ) -> [RemoteTmuxSession] {
        sessions.filter { session in
            if let sessionId = tmuxSessionNumericId(session.id),
               mirroredSessionIds.contains(sessionId) {
                return false
            }
            return !mirroredNames.contains(session.name)
        }
    }

    /// Builds ``MirrorTabActivity`` from per-pane foreground states. Pure;
    /// `activePaneId` is checked first so a multi-pane window names the pane
    /// the user is looking at, then `paneOrder` (the window's layout order).
    static func mirrorTabActivity(
        states: [Int: RemoteTmuxControlConnection.PaneForegroundState],
        paneOrder: [Int],
        activePaneId: Int?
    ) -> MirrorTabActivity {
        let hasActive = states.values.contains { $0.hasActiveCommand }
        var name: String?
        // Focused pane first, then the rest in layout order (filtered so the
        // focused pane isn't revisited); first active, named pane wins.
        let orderedPanes = (activePaneId.map { [$0] } ?? []) + paneOrder.filter { $0 != activePaneId }
        for paneId in orderedPanes {
            guard let state = states[paneId], state.hasActiveCommand, !state.command.isEmpty else { continue }
            name = state.command
            break
        }
        return MirrorTabActivity(hasActiveCommand: hasActive, activeCommandName: name)
    }

    /// Decides how a remote session-end is reflected: close just the dead workspace,
    /// or the whole dedicated window when it lost its last session.
    ///
    /// - Parameters:
    ///   - dedicatedWindowId: the host's dedicated mirror window, or `nil` if the host
    ///     still has other live sessions / was mirrored into a shared window.
    ///   - dedicatedWindowOwnedByEndingHost: `true` only if every workspace in that
    ///     window belongs to the ending host (else a moved-in local/other-host
    ///     workspace would be discarded, so only the dead workspace closes).
    ///   - otherMainWindowCount: OTHER open main windows; the dedicated window closes
    ///     only when >=1 remains, so a disconnect never leaves zero windows.
    /// - Returns: the action to apply.
    nonisolated static func sessionEndAction(
        dedicatedWindowId: UUID?,
        dedicatedWindowOwnedByEndingHost: Bool,
        otherMainWindowCount: Int
    ) -> SessionEndAction {
        if let dedicatedWindowId, dedicatedWindowOwnedByEndingHost, otherMainWindowCount >= 1 {
            return .closeDedicatedWindow(dedicatedWindowId)
        }
        return .closeWorkspace
    }

    /// The `kill-session` target for a user-initiated mirror-workspace close, or
    /// nil when the control client already ended. Closing a leftover workspace
    /// after deliberate detach must not kill the remote session detach promised to
    /// keep alive (#7364).
    nonisolated static func workspaceCloseKillTarget(
        connectionExited: Bool,
        sessionId: Int?,
        sessionName: String
    ) -> String? {
        guard !connectionExited else { return nil }
        return sessionId.map { "$\($0)" } ?? sessionName
    }
}
