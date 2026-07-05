import Foundation

extension RemoteTmuxController {
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
