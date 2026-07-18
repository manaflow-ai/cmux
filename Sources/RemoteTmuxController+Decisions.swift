import Foundation

extension RemoteTmuxController {
    /// A split was requested on a mirror window-tab (the split button / any
    /// bonsplit-level split) → propagate to tmux `split-window`. Covers both
    /// single-pane mirror windows and multi-pane ones. Returns `true` if handled.
    func handleMirrorTabSplitRequested(
        workspaceId: UUID,
        panelId: UUID,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent
    ) -> Bool {
        guard let mirror = sessionMirror(workspaceId: workspaceId) else { return false }
        return mirror.requestSplit(
            windowPanelId: panelId,
            vertical: vertical,
            focusIntent: focusIntent
        )
    }

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
        return sendMirrorNewWindow(command, through: mirror, focus: focus)
    }

    /// Routes a projected control-pane target to a new tmux window immediately
    /// after the window containing that pane. The target pane's authoritative
    /// remote cwd is inherited when available.
    func handleMirrorNewTabRequested(
        workspaceId: UUID,
        targetPaneId: Int,
        focus: Bool
    ) -> Bool {
        guard let mirror = sessionMirror(workspaceId: workspaceId),
              mirror.connection.connectionState == .connected,
              let afterWindowId = mirror.windowIdByPane[targetPaneId] else {
            return false
        }
        let command = Self.newWindowCommand(
            afterWindowId: afterWindowId,
            workingDirectory: mirror.cwdByPane[targetPaneId],
            focus: focus
        )
        return sendMirrorNewWindow(command, through: mirror, focus: focus)
    }

    private func sendMirrorNewWindow(
        _ command: String,
        through mirror: RemoteTmuxSessionMirror,
        focus: Bool
    ) -> Bool {
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

/// The result of ``RemoteTmuxController/createRemoteWorkspace(referenceWorkspaceId:name:surfaceDeadline:)``.
enum RemoteTmuxWorkspaceCreationOutcome {
    /// A new session was created and its mirror surfaced as a workspace. The first
    /// tab's addressable surface id is included when it has already reconciled.
    case created(workspaceId: UUID, surfaceId: UUID?)
    /// The reference workspace has no live remote tmux mirror to spawn a session on.
    case notLinked
    /// The create never reached tmux (the dedicated one-shot returned a failure exit
    /// before creating anything), so NO session exists — a retry is safe.
    case createFailed
    /// tmux created the session, but its mirror has not surfaced yet (the wait
    /// deadline elapsed, or the target view/window went away mid-create). The session
    /// EXISTS and appears on the next reconcile, so its name is returned for recovery
    /// — callers must NOT auto-retry (that would create a duplicate).
    case createdPending(sessionName: String)
    /// The multiplexer create's reply was lost — a control-stream timeout can land
    /// AFTER tmux ran `new-session`, so whether a session was created is unknown.
    /// Callers must NOT auto-retry (it could duplicate); check `list-workspaces`.
    case createIndeterminate
}

extension RemoteTmuxController {
    /// Creates a NEW tmux session on the host backing `referenceWorkspaceId` — the
    /// CLI analogue of the Cmd-N "new workspace on a remote connection" action — so
    /// it links into the shared view and registers as its own cmux workspace, then
    /// returns the new workspace id (and its first tab's surface, once reconciled).
    ///
    /// It rides the SAME primitives the GUI New Workspace path uses
    /// (``RemoteTmuxViewConnection/createWorkspaceReturningName(named:)`` over the
    /// shared stream for the multiplexer, ``mirrorSession`` for the dedicated
    /// transport), so no second SSH connection is opened and the mirror is built by
    /// the one reconcile pipeline — never a parallel reimplementation.
    func createRemoteWorkspace(
        referenceWorkspaceId: UUID,
        name: String?,
        surfaceDeadline: Duration = .seconds(30)
    ) async -> RemoteTmuxWorkspaceCreationOutcome {
        guard let mirror = sessionMirror(workspaceId: referenceWorkspaceId),
              mirror.connection.connectionState == .connected else { return .notLinked }
        let host = mirror.host

        if isMultiplexed(mirror) {
            // Multiplexer: create the session IN BAND over the shared view stream (a
            // one-shot ssh would need a second channel a single-connection host
            // refuses), then nudge the reconcile that links + surfaces it.
            guard let view = multiplexedViewsByHost[host.connectionHash],
                  view.connection?.connectionState == .connected else { return .notLinked }
            guard let sessionName = await view.createWorkspaceReturningName(named: name) else {
                // The stream was connected when we issued the create, so a nil reply
                // is NOT a clean "not created": the send may have dropped (no session)
                // or the reply timed out AFTER tmux ran new-session. We can't tell, so
                // report indeterminate rather than inviting a duplicate-creating retry.
                return .createIndeterminate
            }
            view.requestReconcile()
            // The view can be torn down between the create reply and here; bail with
            // the created name instead of waiting out the full deadline for a mirror
            // that will never surface on this now-dead view.
            guard multiplexedViewsByHost[host.connectionHash] === view else {
                return .createdPending(sessionName: sessionName)
            }
            guard let workspaceId = await awaitNewWorkspace(
                host: host, sessionName: sessionName, deadline: surfaceDeadline
            ) else {
                return .createdPending(sessionName: sessionName)
            }
            return .created(
                workspaceId: workspaceId,
                surfaceId: firstMirrorSurfaceId(host: host, sessionName: sessionName))
        }

        // Dedicated transport: create the session over the shared master, then mirror
        // it into the reference workspace's window (the same window Cmd-N targets).
        let created: String?
        do {
            let result = try await transport(for: host).runTmux(Self.detachedSessionArgv(named: name))
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            created = (result.succeeded && !out.isEmpty) ? out : nil
        } catch {
            created = nil
        }
        guard let sessionName = created else { return .createFailed }
        // The session now EXISTS. From here every failure to mirror it reports the
        // created name (recover) — never a bare failure that invites a duplicate.
        // Revalidate the target window across the ssh round trip (it may have closed).
        guard let manager = mirror.mirroredWorkspace?.owningTabManager
                ?? AppDelegate.shared?.tabManagerFor(tabId: referenceWorkspaceId),
              AppDelegate.shared?.windowId(for: manager) != nil else {
            return .createdPending(sessionName: sessionName)
        }
        do {
            _ = try mirrorSession(host: host, sessionName: sessionName, into: manager, select: false)
        } catch {
            return .createdPending(sessionName: sessionName)
        }
        guard let workspaceId = sessionMirror(host: host, sessionName: sessionName)?.mirroredWorkspaceId else {
            return .createdPending(sessionName: sessionName)
        }
        return .created(
            workspaceId: workspaceId,
            surfaceId: firstMirrorSurfaceId(host: host, sessionName: sessionName))
    }

    /// The addressable surface id of a mirror's first (single-pane) tab, or nil when
    /// it has not reconciled to a drivable surface yet. Best-effort: the workspace id
    /// is the primitive result; the surface is a convenience for immediate driving.
    private func firstMirrorSurfaceId(host: RemoteTmuxHost, sessionName: String) -> UUID? {
        guard let mirror = sessionMirror(host: host, sessionName: sessionName),
              let workspace = mirror.mirroredWorkspace,
              let firstWindowId = mirror.connection.windowOrder.first,
              let panelId = mirror.panelIdByWindow[firstWindowId],
              let panel = workspace.terminalPanel(for: panelId) else { return nil }
        return panel.surface.id
    }

    /// `new-session` argv for a dedicated one-shot create: prints the auto-assigned
    /// name, and requests an explicit name when one is given (dropped if it carries
    /// characters tmux forbids in a session name).
    nonisolated static func detachedSessionArgv(named: String?) -> [String] {
        var argv = ["new-session", "-d", "-P", "-F", "#{session_name}"]
        if let named, let safe = RemoteTmuxHost.controlModeCommandName(named) {
            argv += ["-s", safe]
        }
        return argv
    }
}
