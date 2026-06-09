import Foundation

/// Mirrors one remote tmux session into a dedicated cmux sidebar workspace.
///
/// Owns the binding between a ``RemoteTmuxControlConnection`` and a ``Workspace``:
/// each tmux window becomes a tab (rendering that window's first pane via a
/// MANUAL-I/O display surface), pane output is routed to the right tab, and the
/// workspace's default local terminal tab is closed once remote tabs exist.
///
/// Full pane→split mapping and window-close handling build on this first
/// session→workspace increment.
@MainActor
final class RemoteTmuxSessionMirror {
    let host: RemoteTmuxHost
    private(set) var sessionName: String
    let connection: RemoteTmuxControlConnection

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

    private weak var workspace: Workspace?
    private let defaultPanelIds: [UUID]
    private var defaultClosed = false
    private var panelIdByWindow: [Int: UUID] = [:]
    private var panelIdByPane: [Int: UUID] = [:]
    /// Last-known working directory per tmux pane, so switching the active pane of
    /// a multi-pane window can re-project that pane's directory onto the tab.
    private var cwdByPane: [Int: String] = [:]
    /// Per-window multi-pane renderers (present once a window has >1 pane).
    private var windowMirrorByWindowId: [Int: RemoteTmuxWindowMirror] = [:]
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        connection: RemoteTmuxControlConnection,
        workspace: Workspace
    ) {
        self.host = host
        self.sessionName = sessionName
        self.connection = connection
        self.workspace = workspace
        self.defaultPanelIds = Array(workspace.panels.keys)

        // Register as one of possibly several observers — never overwrite a
        // single shared closure on the connection.
        self.observerToken = connection.addObserver(
            onPaneOutput: { [weak self] paneId, data in
                self?.routeOutput(paneId: paneId, data: data)
            },
            onPaneCwd: { [weak self] paneId, path in
                self?.handlePaneCwd(paneId: paneId, path: path)
            },
            onPaneReflow: { [weak self] paneId, noReflow in
                self?.routeNoReflow(paneId: paneId, noReflow: noReflow)
            },
            onActivePaneChanged: { [weak self] windowId, paneId in
                self?.handleActivePaneChanged(windowId: windowId, paneId: paneId)
            },
            onTopologyChanged: { [weak self] in
                self?.rebuild()
            },
            onExit: { [weak self] in
                self?.handleConnectionExited()
            }
        )
        rebuild()
    }

    /// The remote session ended for good (its last tmux window was killed, it was
    /// killed out-of-band, or a reconnect found it gone) — hand off to the controller
    /// to remove the mirror and close the now-dead workspace. A transient transport
    /// loss does NOT reach here (the connection reconnects); deliberate detach / quit
    /// / window close suppress `onExit`. So this only runs for genuine remote ends.
    private func handleConnectionExited() {
        guard let workspaceId = mirroredWorkspaceId else { return }
        AppDelegate.shared?.remoteTmuxController.handleSessionEndedRemotely(
            host: host, sessionName: sessionName, workspaceId: workspaceId
        )
    }

    /// The cmux workspace mirroring this session (if still alive).
    var mirroredWorkspaceId: UUID? { workspace?.id }

    /// The tmux window id whose mirrored tab is backed by `panelId`, if any.
    func windowId(forPanel panelId: UUID) -> Int? {
        panelIdByWindow.first(where: { $0.value == panelId })?.key
    }

    /// Deregisters this mirror's connection observer and tears down all per-window
    /// multi-pane renderers (called when the mirror is torn down so its callbacks
    /// don't linger on a shared connection and its pane surfaces don't leak).
    func detachObserver() {
        if let observerToken {
            connection.removeObserver(observerToken)
            self.observerToken = nil
        }
        for (windowId, mirror) in windowMirrorByWindowId {
            workspace?.setRemoteTmuxWindowMirror(nil, forPanelId: mirror.panelId)
            mirror.teardown()
            windowMirrorByWindowId[windowId] = nil
        }
    }

    /// The tmux window id (if any) whose layout currently contains `paneId`.
    private func windowIdContaining(pane paneId: Int) -> Int? {
        connection.windowsByID.first(where: { $0.value.paneIDsInOrder.contains(paneId) })?.key
    }

    /// Adds a tab for any window that doesn't yet have one, refreshes existing
    /// tab titles after a tmux rename, activates/reconciles the in-tab multi-pane
    /// renderer for multi-pane windows, then closes the workspace's original
    /// local tab(s) once at least one remote tab exists.
    func rebuild() {
        guard let workspace else { return }
        for windowId in connection.windowOrder {
            guard let window = connection.windowsByID[windowId],
                  let firstPaneId = window.paneIDsInOrder.first else { continue }
            let title = Self.tabTitle(for: window)
            let panelId: UUID
            if let existing = panelIdByWindow[windowId] {
                // Existing tab — refresh its title if tmux renamed the window.
                workspace.updateRemoteTmuxTabTitle(panelId: existing, title: title)
                panelId = existing
            } else {
                guard let panel = workspace.addRemoteTmuxDisplayPane(
                    remotePaneId: firstPaneId,
                    title: title,
                    focus: false,
                    onInput: { [weak connection] data in
                        Task { @MainActor in connection?.sendKeys(paneId: firstPaneId, data: data) }
                    },
                    // Size the remote tmux client to the rendered grid so a single-
                    // pane window (the common case — where a claude / claude agents
                    // TUI runs) doesn't stay at ssh's default 80×24 and render
                    // mangled. The multi-pane path handles this via the window
                    // mirror's own geometry.
                    onResize: { [weak connection] columns, rows in
                        connection?.setClientSize(columns: columns, rows: rows)
                    }
                ) else { continue }
                panelIdByWindow[windowId] = panel.id
                panelIdByPane[firstPaneId] = panel.id
                connection.capturePane(paneId: firstPaneId)
                // Classify the pane (shell → reflow on resize; TUI/alt-screen → no
                // reflow). One-shot first (always works) so a shell reflows even on
                // tmux builds where the live subscription doesn't deliver, then the
                // subscription for live re-classification (e.g. bash → node).
                connection.requestPaneReflow(paneId: firstPaneId)
                connection.subscribePaneReflow(paneId: firstPaneId)
                // Track the pane's working directory so the tab shows the remote
                // cwd (initial value + live `cd`) instead of staying at "~".
                connection.requestPanePath(paneId: firstPaneId)
                connection.subscribePanePath(paneId: firstPaneId)
                panelId = panel.id
            }
            reconcileWindowMirror(windowId: windowId, panelId: panelId, window: window, in: workspace)
        }
        // Close tabs for windows tmux removed, so a closed remote window doesn't
        // leave a frozen tab behind.
        let liveWindows = Set(connection.windowOrder)
        for (windowId, panelId) in panelIdByWindow where !liveWindows.contains(windowId) {
            if let mirror = windowMirrorByWindowId[windowId] {
                workspace.setRemoteTmuxWindowMirror(nil, forPanelId: panelId)
                mirror.teardown()
                windowMirrorByWindowId[windowId] = nil
            }
            _ = workspace.closePanel(panelId, force: true)
            panelIdByWindow[windowId] = nil
            panelIdByPane = panelIdByPane.filter { $0.value != panelId }
        }
        // Drop cached directories for panes tmux no longer reports, so the cache
        // stays bounded across window/pane churn (tmux pane ids never recur).
        let livePanes = Set(connection.windowsByID.values.flatMap { $0.paneIDsInOrder })
        cwdByPane = cwdByPane.filter { livePanes.contains($0.key) }
        closeDefaultTabsIfNeeded()
        // Follow out-of-band tmux window reorders (a second client, or a manual
        // move-window / a new-window inserted mid-list): the cmux tabs are created
        // in arrival order and appended, so a non-tail change leaves the strip
        // stale. Reorder to match tmux's reported order, preserving focus. The
        // cmux→tmux drag direction is handled by handleMirrorWindowsReordered and
        // already matches, so this no-ops there.
        let desiredPanelOrder = connection.windowOrder.compactMap { panelIdByWindow[$0] }
        if desiredPanelOrder.count > 1 {
            workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder: desiredPanelOrder)
        }
    }

    /// Creates the in-tab multi-pane renderer the first time a window has more
    /// than one pane, and reconciles it on subsequent layout changes. Once
    /// created it persists for that window (rendering even a single pane), so the
    /// tab never flips back and forth between the two render paths.
    private func reconcileWindowMirror(
        windowId: Int,
        panelId: UUID,
        window: RemoteTmuxWindow,
        in workspace: Workspace
    ) {
        if let mirror = windowMirrorByWindowId[windowId] {
            mirror.reconcile(layout: window.layout)
            return
        }
        guard window.paneIDsInOrder.count > 1 else { return }
        let mirror = RemoteTmuxWindowMirror(
            windowId: windowId,
            panelId: panelId,
            connection: connection,
            layout: window.layout,
            makePanel: { [weak workspace, weak connection] tmuxPaneId in
                workspace?.makeRemoteTmuxPanePanel(onInput: { data in
                    Task { @MainActor in connection?.sendKeys(paneId: tmuxPaneId, data: data) }
                })
            }
        )
        windowMirrorByWindowId[windowId] = mirror
        workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: panelId)
        // The window mirror now owns client sizing for this window (it sends
        // refresh-client -C for the whole multi-pane area). Clear the original
        // single-pane display surface's resize hook so both paths don't drive the
        // same connection with differently-computed sizes.
        if let panel = workspace.panels[panelId] as? TerminalPanel {
            panel.surface.onManualGridResize = nil
        }
    }

    /// The tab title for a mirrored window: the tmux window name, or a localized
    /// placeholder when tmux hasn't reported one. tmux window names are
    /// content-derived (like every other cmux tab title) so the name itself is
    /// not translated; only the empty-name placeholder is localized.
    private static func tabTitle(for window: RemoteTmuxWindow) -> String {
        let trimmed = window.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            ? String(localized: "remoteTmux.tab.window", defaultValue: "tmux window")
            : trimmed
    }

    private func closeDefaultTabsIfNeeded() {
        guard !defaultClosed, !panelIdByWindow.isEmpty, let workspace else { return }
        for panelId in defaultPanelIds where workspace.panels[panelId] != nil {
            _ = workspace.closePanel(panelId, force: true)
        }
        defaultClosed = true
    }

    /// Routes a pane's reported working directory to the tab that renders it: a
    /// single-pane window updates its display tab; a multi-pane window updates its
    /// window tab only when the reporting pane is the window's active pane, so a
    /// background pane's `cd` can't hijack the tab's folder. No-ops for unknown panes.
    private func handlePaneCwd(paneId: Int, path: String) {
        guard let workspace else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cwdByPane[paneId] = trimmed
        guard let panelId = tabPanelId(forPane: paneId) else { return }
        // Multi-pane window: only the active pane represents the tab.
        if let windowId = windowIdContaining(pane: paneId),
           windowMirrorByWindowId[windowId] != nil,
           activePane(inWindow: windowId) != paneId {
            return
        }
        _ = workspace.updatePanelDirectory(panelId: panelId, directory: trimmed)
    }

    /// Re-projects the newly-active pane's cached directory onto its multi-pane
    /// window tab when the active pane changes, so switching panes updates the
    /// folder immediately (rather than waiting for that pane's next `cd`).
    private func handleActivePaneChanged(windowId: Int, paneId: Int) {
        guard let workspace,
              windowMirrorByWindowId[windowId] != nil,
              let panelId = panelIdByWindow[windowId],
              let path = cwdByPane[paneId] else { return }
        _ = workspace.updatePanelDirectory(panelId: panelId, directory: path)
    }

    /// The panel id of the tab that renders `paneId`: a single-pane window's
    /// display tab, or a multi-pane window's window tab.
    private func tabPanelId(forPane paneId: Int) -> UUID? {
        panelIdByPane[paneId] ?? windowIdContaining(pane: paneId).flatMap { panelIdByWindow[$0] }
    }

    /// The pane that currently represents `windowId`'s tab: the user-focused mirror
    /// pane, else tmux's active pane, else the window's first pane.
    private func activePane(inWindow windowId: Int) -> Int? {
        windowMirrorByWindowId[windowId]?.activePaneId
            ?? connection.activePaneByWindow[windowId]
            ?? connection.windowsByID[windowId]?.paneIDsInOrder.first
    }

    private func routeOutput(paneId: Int, data: Data) {
        // Multi-pane window: its in-tab renderer owns the pane's surface.
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.routeOutput(paneId: paneId, data: data)
            return
        }
        // Single-pane window: route to the window-tab's panel surface.
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.processRemoteOutput(data)
    }

    /// Applies a pane's reflow classification to its mirror surface (suppress
    /// reflow on resize for alt-screen / inline-TUI panes; allow it for shells).
    /// Routes exactly like ``routeOutput(paneId:data:)`` — multi-pane windows own
    /// their pane surfaces, single-pane windows use the tab's panel surface.
    private func routeNoReflow(paneId: Int, noReflow: Bool) {
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.surface(forPane: paneId)?.setManualIONoReflow(noReflow)
            return
        }
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.setManualIONoReflow(noReflow)
    }

    /// Routes a split of a mirror window-tab (by its panel id) to tmux
    /// `split-window`, splitting the focused pane (or the window's only pane).
    /// Used by the split BUTTON / `shouldSplitPane` path, which works at the
    /// bonsplit-pane (tab) level rather than per mirror surface. Returns `true`
    /// if handled (the caller vetoes the local split).
    func requestSplit(windowPanelId panelId: UUID, vertical: Bool) -> Bool {
        guard !connection.exited, let windowId = windowId(forPanel: panelId) else { return false }
        let targetPane = windowMirrorByWindowId[windowId]?.activePaneId
            ?? connection.windowsByID[windowId]?.paneIDsInOrder.first
        guard let targetPane else { return false }
        connection.send("split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(targetPane)")
        return true
    }

    /// Whether `surfaceId` is one of this session mirror's pane surfaces — a
    /// single-pane display tab or any multi-pane window-mirror pane. Used to route
    /// a pasted image to this mirror's tmux host for SSH upload.
    func ownsSurface(_ surfaceId: UUID) -> Bool {
        paneId(forSurfaceId: surfaceId) != nil
    }

    /// The tmux pane id whose surface is `surfaceId` (single-pane display tab or
    /// multi-pane window-mirror pane), or nil if this mirror doesn't render it.
    /// Used to target a tmux paste at the pane behind a cmux surface.
    func paneId(forSurfaceId surfaceId: UUID) -> Int? {
        if let match = windowMirror(forSurfaceId: surfaceId) { return match.tmuxPaneId }
        guard let workspace else { return nil }
        for (paneId, panelId) in panelIdByPane
        where (workspace.panels[panelId] as? TerminalPanel)?.surface.id == surfaceId {
            return paneId
        }
        return nil
    }

    /// The multi-pane renderer + tmux pane id for a focused mirror surface, used
    /// by the split shortcut to route ⌘D to `split-window`.
    func windowMirror(forSurfaceId surfaceId: UUID) -> (mirror: RemoteTmuxWindowMirror, tmuxPaneId: Int)? {
        for mirror in windowMirrorByWindowId.values {
            for paneId in mirror.paneIDsInOrder {
                if mirror.surface(forPane: paneId)?.id == surfaceId {
                    return (mirror, paneId)
                }
            }
        }
        return nil
    }
}
