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
            onTopologyChanged: { [weak self] in
                self?.rebuild()
            },
            onExit: { [weak self] in
                self?.handleConnectionExited()
            }
        )
        rebuild()
    }

    /// The remote session ended on its own (e.g. its last tmux window was killed,
    /// or it was killed out-of-band) — hand off to the controller to remove the
    /// mirror and close the now-dead workspace. Deliberate detach/quit/window
    /// close suppress `onExit`, so this only runs for genuine remote ends.
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
                    }
                ) else { continue }
                panelIdByWindow[windowId] = panel.id
                panelIdByPane[firstPaneId] = panel.id
                connection.capturePane(paneId: firstPaneId)
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
        closeDefaultTabsIfNeeded()
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
