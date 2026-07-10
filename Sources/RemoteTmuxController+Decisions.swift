import Foundation

extension RemoteTmuxController {
    /// A new tab was requested in a mirrored workspace → create a tmux window in
    /// that session. The new tab arrives via the `%window-add` notification (one
    /// source of truth), so the caller must NOT also create a local tab.
    ///
    /// `placement` mirrors cmux's `newTabPosition` for the workspace tab strip so
    /// a remote new tab lands where a local one would (after the selected tab, or
    /// at the end), instead of wherever tmux's bare `new-window` picks (the lowest
    /// free index, which lands mid-list when the session has window-index gaps).
    ///
    /// Requires a live `.connected` stream — NOT just `!exited`: while
    /// reconnecting there is no stdin and `send` silently drops the command, so
    /// returning `true` would let socket callers report an accepted mutation
    /// that never reached tmux.
    ///
    /// - Parameter workingDirectory: the directory the new tmux window should
    ///   start in (the active tab's cwd, resolved by the caller), so a new tab
    ///   inherits the active tab's directory the way local cmux does. A
    ///   nil/blank/unsafe value, or a source panel that is not backed by a live
    ///   mirror window, omits `-c` and lets tmux pick its default-path.
    /// - Parameter focus: whether this request explicitly intends to select and
    ///   focus the created mirror tab. Background requests use tmux's `-d` and
    ///   never enqueue local focus.
    /// - Returns: `true` if routed to the remote; `false` if there is no live
    ///   mirror/connection (callers must still NOT create a local tab in a
    ///   mirror workspace — they report failure instead).
    func handleMirrorNewTabRequested(
        workspaceId: UUID,
        placement: RemoteTmuxMirrorNewTabPlacement,
        workingDirectory: String?,
        workingDirectorySourcePanelId: UUID?,
        focus: Bool
    ) -> Bool {
        guard let mirror = sessionMirror(workspaceId: workspaceId),
              mirror.connection.connectionState == .connected else { return false }
        let afterWindowId: Int?
        switch placement {
        case .end:
            afterWindowId = nil
        case .afterPanel(let panelId):
            afterWindowId = mirror.windowId(forPanel: panelId)
        }
        let commandWorkingDirectory = Self.liveMirrorWindowWorkingDirectory(
            workingDirectory,
            sourcePanelId: workingDirectorySourcePanelId,
            windowIdForPanel: mirror.windowId(forPanel:)
        )
        let command = Self.newWindowCommand(
            afterWindowId: afterWindowId,
            workingDirectory: commandWorkingDirectory,
            focus: focus
        )
        guard focus else { return mirror.connection.send(command) }
        return mirror.connection.sendNewWindow(command) { [weak mirror] windowId in
            guard let windowId else { return }
            mirror?.focusWindowWhenAvailable(windowId)
        }
    }

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
    /// - nil -> `new-window -d -a -t '{end}'`: `-a` inserts *after* the target and
    ///   `'{end}'` resolves to the highest-indexed window, so the new window lands
    ///   at the very end regardless of index gaps or which window tmux considers
    ///   current. (`'{end}'` is an alias for `$`, available since tmux 2.1.) Plain
    ///   `new-window` instead fills the lowest free index, landing mid-list when
    ///   the session has gaps from closed windows.
    /// - id -> `new-window -d -a -t @id`: insert right after that window. cmux never
    ///   `select-window`s the remote, so the selected tab's window is targeted by
    ///   id rather than relying on tmux's current window.
    ///
    /// Working directory: when non-blank, appends `-c '<path>'` so the new tab
    /// opens in the active tab's directory (like a local new tab). Without `-c`,
    /// tmux uses its default-path. The path is single-quoted so spaces and shell
    /// metacharacters survive tmux's parser (the quoting the `rename-*` commands
    /// use on this stream); a path carrying CR/LF/control bytes that could
    /// terminate the command line is dropped, leaving the placement-only command.
    /// Background requests add `-d`; focused requests ask tmux to print the stable
    /// new window id so focus can be applied only after the mirror tab exists.
    nonisolated static func newWindowCommand(
        afterWindowId: Int?,
        workingDirectory: String?,
        focus: Bool = false
    ) -> String {
        var command = focus
            ? "new-window -P -F '#{window_id}'"
            : "new-window -d"
        command += afterWindowId.map { " -a -t @\($0)" } ?? " -a -t '{end}'"
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty,
           RemoteTmuxHost.controlModeLineSafeName(directory) != nil {
            command += " -c \(RemoteTmuxHost.shellSingleQuoted(directory))"
        }
        return command
    }

    /// Builds the commands that selection-sort `current` into `desired` using
    /// stable tmux window ids and detached swaps.
    nonisolated static func mirrorWindowReorderCommands(
        current: [Int],
        desired: [Int]
    ) -> [String] {
        var working = current
        var indexByWindow = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($1, $0) })
        var commands: [String] = []
        for index in desired.indices where working[index] != desired[index] {
            let targetWindow = desired[index]
            guard let swapFrom = indexByWindow[targetWindow] else { continue }
            let displacedWindow = working[index]
            commands.append(
                "swap-window -d -s @\(working[index]) -t @\(working[swapFrom])"
            )
            working.swapAt(index, swapFrom)
            indexByWindow[targetWindow] = index
            indexByWindow[displacedWindow] = swapFrom
        }
        return commands
    }

    /// Pushes a local mirror-tab reorder to tmux as one detached swap batch.
    /// Rejected synchronous sends rebuild from the connection ledger; an async
    /// tmux `%error` triggers an authoritative `list-windows` reconciliation.
    func handleMirrorWindowsReordered(
        workspaceId: UUID,
        orderedPanelIds: [UUID],
        verification: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let mirror = sessionMirror(workspaceId: workspaceId) else { return false }
        guard mirror.connection.connectionState == .connected else {
            mirror.rebuild()
            return false
        }
        let desired = orderedPanelIds.compactMap { mirror.windowId(forPanel: $0) }
        guard desired.count == orderedPanelIds.count else { mirror.rebuild(); return false }
        guard desired.count >= 2 else {
            verification?(true)
            return true
        }
        let desiredSet = Set(desired)
        let current = mirror.connection.windowOrder.filter { desiredSet.contains($0) }
        guard current.count == desired.count, Set(current) == desiredSet else {
            mirror.rebuild()
            return false
        }
        guard current != desired else {
            verification?(true)
            return true
        }
        let commands = Self.mirrorWindowReorderCommands(current: current, desired: desired)
        guard mirror.connection.sendWindowReorder(commands, verification: verification) else {
            mirror.rebuild()
            return false
        }
        mirror.connection.applyWindowReorder(desired)
        return true
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
    nonisolated static func mirrorTabActivity(
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
