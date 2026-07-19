import Bonsplit
import Foundation
import CmuxRemoteSession

/// Mirrors one remote tmux session into a dedicated cmux sidebar workspace.
///
/// Owns the binding between a ``RemoteTmuxControlConnection`` and a ``Workspace``:
/// each tmux window becomes a tab, pane output is routed to its stable local
/// surface, and the workspace's default local tab is closed once mirrors exist.
@MainActor
final class RemoteTmuxSessionMirror: RemoteTmuxControlPaneMutationOwner {
    let host: RemoteTmuxHost
    private(set) var sessionName: String
    /// Discovery's stable tmux session id (`$N`), seeded at creation so id-based
    /// de-dup works before the control stream reports `connection.sessionId`.
    let seededSessionId: Int?
    let connection: RemoteTmuxControlConnection
    let onControlPaneRemoved: (PaneID, UUID?) -> Void
    let onControlSurfaceRemoved: (UUID) -> Void

    /// Updates the tracked session name after a `rename-session`.
    func setSessionName(_ name: String) { sessionName = name }

    /// Sizing introspection for every mirrored multi-pane window (see
    /// ``RemoteTmuxWindowMirror/sizingSnapshot()``), ordered by window id.
    func sizingSnapshots() -> [RemoteTmuxWindowMirror.SizingSnapshot] {
        windowMirrorByWindowId.keys.sorted()
            .compactMap { windowMirrorByWindowId[$0]?.sizingSnapshot() }
    }

    /// Re-titles the mirror's sidebar workspace to track a remote session rename
    /// (the reverse of the cmux→tmux `rename-session` push). Uses TabManager's
    /// title path so selected-window chrome refreshes, while suppressing the
    /// `rename-session` propagation that would otherwise feed back on itself.
    /// The remote session name is the source of truth for a mirror workspace's
    /// title, mirroring how a remote window rename unconditionally re-titles its
    /// tab, so this overwrites any local custom title.
    func applySessionNameToWorkspaceTitle(_ name: String) {
        guard let safe = RemoteTmuxHost.controlModeLineSafeName(name) else { return }
        guard let workspace else { return }
        let currentManager = workspace.owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id)
            ?? tabManager
        if currentManager?.setCustomTitle(
            tabId: workspace.id,
            title: safe,
            propagateToRemoteTmux: false
        ) == true {
            return
        }
        _ = workspace.setCustomTitle(safe)
    }

    private weak var tabManager: TabManager?
    weak var workspace: Workspace?
    /// The workspace currently backing this mirror, if it has not been released.
    var mirroredWorkspace: Workspace? { workspace }
    private let defaultPanelIds: [UUID]
    private var defaultClosed = false
    var panelIdByWindow: [Int: UUID] = [:]
    var windowIdByPanel: [UUID: Int] = [:]
    var panelIdByPane: [Int: UUID] = [:]
    var windowIdByPane: [Int: Int] = [:]
    var controlPaneIdByPane: [Int: PaneID] = [:]
    var controlSurfaceIdByPane: [Int: UUID] = [:]
    /// Last-known working directory per tmux pane, so switching the active pane of
    /// a multi-pane window can re-project that pane's directory onto the tab.
    var cwdByPane: [Int: String] = [:]
    /// Per-pane filter that strips the screen/tmux `ESC k <title> ST` window-title
    /// escape from `%output` (stateful across chunk boundaries).
    private var titleFilters: [Int: RemoteTmuxScreenTitleFilter] = [:]
    /// Per-window multi-pane renderers (present once a window has >1 pane).
    var windowMirrorByWindowId: [Int: RemoteTmuxWindowMirror] = [:]
    private var pendingExplicitFocusWindowId: Int?
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        seededSessionId: Int? = nil,
        connection: RemoteTmuxControlConnection,
        tabManager: TabManager,
        workspace: Workspace,
        onControlPaneRemoved: @escaping (PaneID, UUID?) -> Void = { _, _ in },
        onControlSurfaceRemoved: @escaping (UUID) -> Void = { _ in }
    ) {
        self.host = host
        self.sessionName = sessionName
        self.seededSessionId = seededSessionId
        self.connection = connection
        self.onControlPaneRemoved = onControlPaneRemoved
        self.onControlSurfaceRemoved = onControlSurfaceRemoved
        self.tabManager = tabManager
        self.workspace = workspace
        self.defaultPanelIds = Array(workspace.panels.keys)
        workspace.remoteTmuxSessionMirror = self

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
            onSessionChanged: { [weak self] oldName, newName in
                self?.handleSessionNameChanged(oldName: oldName, newName: newName)
            },
            onTopologyChanged: { [weak self] in
                self?.rebuild()
            },
            onReconnectReady: { [weak self] in
                self?.forceResizeAllVisibleMirrors()
            },
            onExit: { [weak self] in
                self?.handleConnectionExited()
            },
            onConnectionStateChanged: { [weak self] state in
                // Drop any mid-`ESC k` title-filter state when the stream isn't live:
                // a reconnect's `reseedAfterReconnect` re-emits clear/capture bytes,
                // and a filter stuck mid-title from before the drop would swallow them.
                // Resetting on the disconnect edge is ordering-independent (no output
                // arrives while not connected).
                if state != .connected { self?.titleFilters.removeAll() }
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

    /// Tmux confirmed a session rename. The controller owns the session-keyed
    /// dictionaries, so it performs the re-key and then updates this mirror.
    private func handleSessionNameChanged(oldName: String, newName: String) {
        AppDelegate.shared?.remoteTmuxController.handleMirrorSessionNameChanged(
            mirror: self,
            oldName: oldName,
            newName: newName
        )
    }

    /// The cmux workspace mirroring this session (if still alive).
    var mirroredWorkspaceId: UUID? { workspace?.id }

    /// The tmux window id whose mirrored tab is backed by `panelId`, if any.
    func windowId(forPanel panelId: UUID) -> Int? {
        windowIdByPanel[panelId]
    }

    /// Deregisters this mirror's connection observer and tears down all per-window
    /// multi-pane renderers (called when the mirror is torn down so its callbacks
    /// don't linger on a shared connection and its pane surfaces don't leak).
    func detachObserver() {
        if let observerToken {
            connection.removeObserver(observerToken)
            self.observerToken = nil
        }
        teardownControlPaneIdentities()
        workspace?.remoteTmuxWindowOrderSync = nil
        if workspace?.remoteTmuxSessionMirror === self {
            workspace?.remoteTmuxSessionMirror = nil
        }
        // Detach owns the whole mirror set, so prune the sizing ledger once.
        // Each mirror's teardown then sees no claim and avoids rescanning the
        // shrinking maxima table once per window.
        connection.retainWindowSizeClaims(for: [])
        for mirror in windowMirrorByWindowId.values {
            workspace?.setRemoteTmuxWindowMirror(nil, forPanelId: mirror.panelId)
            mirror.teardown()
        }
        windowMirrorByWindowId.removeAll()
        windowIdByPanel.removeAll()
        windowIdByPane.removeAll()
    }

    /// The tmux window id (if any) whose layout currently contains `paneId`.
    private func windowIdContaining(pane paneId: Int) -> Int? {
        windowIdByPane[paneId]
    }

    func rebuild() {
        guard let workspace else { return }
        workspace.performRemoteTmuxMirrorMutation {
            rebuildTopology(in: workspace)
        }
        focusExplicitlyRequestedWindowIfAvailable()
    }

    private func rebuildTopology(in workspace: Workspace) {
        let livePanes = Set(connection.windowsByID.values.flatMap { $0.paneIDsInOrder })
            .union(connection.paneIDsRetainedUntilWindowList)
        let pendingPanes = Set(connection.pendingLayouts.values.flatMap { $0.node.paneIDsInOrder })
        reconcileControlPaneIdentities(livePaneIDs: livePanes.union(pendingPanes))
        windowIdByPane = connection.publishedWindowIdByPane
        for windowId in connection.windowOrder {
            guard let window = connection.windowsByID[windowId],
                  let firstPaneId = window.paneIDsInOrder.first else { continue }
            let title = Self.tabTitle(for: window)
            let panelId: UUID
            let displayPanelWasCreated: Bool
            if let existing = panelIdByWindow[windowId] {
                // Existing tab — refresh its title if tmux renamed the window.
                workspace.updateRemoteTmuxTabTitle(panelId: existing, title: title)
                panelId = existing
                displayPanelWasCreated = false
            } else {
                guard let panel = workspace.addRemoteTmuxDisplayPane(
                    remotePaneId: firstPaneId,
                    title: title,
                    focus: false,
                    onInput: { [weak connection] data in
                        Task { @MainActor in connection?.sendKeys(paneId: firstPaneId, data: data) }
                    },
                    // A single-pane display drives this window from its rendered
                    // grid; multi-pane sizing transfers to the window mirror below.
                    onResize: { [weak connection] columns, rows in
                        connection?.setWindowSize(windowId: windowId, columns: columns, rows: rows)
                    }
                ) else { continue }
                panelIdByWindow[windowId] = panel.id
                windowIdByPanel[panel.id] = windowId
                panelIdByPane[firstPaneId] = panel.id
                // Claim from either runtime readiness or a later manual resize;
                // adoption below replaces both hooks at the ownership boundary.
                if let terminalPanel = workspace.panels[panel.id] as? TerminalPanel {
                    let surface = terminalPanel.surface
                    surface.onRuntimeReady = { [weak connection, weak surface] in
                        guard let grid = surface?.renderedGridCells() else { return }
                        connection?.setWindowSize(
                            windowId: windowId, columns: grid.columns, rows: grid.rows
                        )
                    }
                    surface.onManualSizeApplied = { [weak connection] sample in
                        connection?.setWindowSize(
                            windowId: windowId, columns: sample.columns, rows: sample.rows
                        )
                    }
                }
                if Self.shouldSeedSinglePaneDisplay(for: window) {
                    connection.seedPane(paneId: firstPaneId)
                }
                panelId = panel.id
                displayPanelWasCreated = true
            }
            if window.paneIDsInOrder.count == 1,
               windowMirrorByWindowId[windowId] == nil,
               let panel = workspace.panels[panelId] as? TerminalPanel {
                updateControlSurface(
                    tmuxPaneID: firstPaneId,
                    surfaceID: panel.id,
                    windowID: windowId
                )
            }
            reconcileWindowMirror(
                windowId: windowId,
                panelId: panelId,
                window: window,
                displayPanelWasCreated: displayPanelWasCreated,
                in: workspace
            )
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
            _ = workspace.removeRemoteTmuxDisplayPane(panelId)
            panelIdByWindow[windowId] = nil
            windowIdByPanel[panelId] = nil
            panelIdByPane = panelIdByPane.filter { $0.value != panelId }
        }
        // Belt for a mirror that outlived its panel bookkeeping: a mirror
        // whose window tmux no longer lists must die even if the
        // panel-by-window entry was already gone (a server restart inside a
        // reused workspace once left a corpse mirror claiming and being
        // judged against a window id that no longer existed — it could
        // never settle, and its tree kept replanning against live
        // container sizes with no layouts ever arriving).
        for (windowId, mirror) in windowMirrorByWindowId where !liveWindows.contains(windowId) {
            mirror.teardown()
            windowMirrorByWindowId[windowId] = nil
        }
        // A dead window's size claims die with the authoritative topology.
        // Prune the whole ledger once: removing each dead window separately
        // rescans the remaining claims for maxima and turns batch churn into
        // quadratic work.
        connection.retainWindowSizeClaims(for: liveWindows)
        // Drop cached directories for panes tmux no longer reports, so the cache
        // stays bounded across window/pane churn (tmux pane ids never recur).
        panelIdByPane = panelIdByPane.filter { livePanes.contains($0.key) }
        cwdByPane = cwdByPane.filter { livePanes.contains($0.key) }
        titleFilters = titleFilters.filter { livePanes.contains($0.key) }
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

    /// Applies explicit focus only after the corresponding mirror tab exists and
    /// the focus-neutral topology transaction has completed.
    func focusWindowWhenAvailable(_ windowId: Int) {
        pendingExplicitFocusWindowId = windowId
        focusExplicitlyRequestedWindowIfAvailable()
    }

    private func focusExplicitlyRequestedWindowIfAvailable() {
        guard let windowId = pendingExplicitFocusWindowId,
              let panelId = panelIdByWindow[windowId],
              let workspace else { return }
        pendingExplicitFocusWindowId = nil
        workspace.focusPanel(panelId)
    }

    private func closeDefaultTabsIfNeeded() {
        guard !defaultClosed, !panelIdByWindow.isEmpty, let workspace else { return }
        for panelId in defaultPanelIds where workspace.panels[panelId] != nil {
            _ = workspace.removeRemoteTmuxDisplayPane(panelId)
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
        if let windowId = windowIdContaining(pane: paneId) {
            windowMirrorByWindowId[windowId]?.updatePaneCwd(paneId: paneId, path: trimmed)
        }
        guard let panelId = tabPanelId(forPane: paneId) else { return }
        // Multi-pane window: only the active pane represents the tab.
        if let windowId = windowIdContaining(pane: paneId),
           windowMirrorByWindowId[windowId] != nil,
           activePane(inWindow: windowId) != paneId {
            return
        }
        _ = workspace.updateRemotePanelDirectoryWithMetadata(panelId: panelId, directory: trimmed)
    }

    /// Re-projects the newly-active pane's cached directory onto its multi-pane
    /// window tab when the active pane changes, so switching panes updates the
    /// folder immediately (rather than waiting for that pane's next `cd`).
    private func handleActivePaneChanged(windowId: Int, paneId: Int) {
        // The strip dot must show TMUX's active pane, not just local focus:
        // a co-attached client's pane switch arrives here and nowhere else.
        windowMirrorByWindowId[windowId]?.noteRemoteActivePane(paneId)
        guard let workspace,
              windowMirrorByWindowId[windowId] != nil,
              let panelId = panelIdByWindow[windowId],
              let path = cwdByPane[paneId] else { return }
        _ = workspace.updateRemotePanelDirectoryWithMetadata(panelId: panelId, directory: path)
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
        // Strip the screen/tmux `ESC k <title> ST` window-title escape that a remote
        // shell (TERM=screen*/tmux*) emits — the mirror's xterm-style surface would
        // otherwise print the title text onto the screen (see
        // ``RemoteTmuxScreenTitleFilter``). Per-pane state survives chunk splits.
        var filter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        let cleaned = filter.filter(data)
        titleFilters[paneId] = filter

        // Multi-pane window: its in-tab renderer owns the pane's surface.
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.routeOutput(paneId: paneId, data: cleaned)
            return
        }
        // Single-pane window: route to the window-tab's panel surface.
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.processRemoteOutput(cleaned)
    }

    /// Applies a pane's reflow classification to its mirror surface (suppress
    /// reflow on resize for alt-screen / inline-TUI panes; allow it for shells).
    /// Routes exactly like ``routeOutput(paneId:data:)`` — multi-pane windows own
    /// their pane surfaces, single-pane windows use the tab's panel surface.
    private func routeNoReflow(paneId: Int, noReflow: Bool) {
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.surface(forPane: paneId)?.setManualIONoReflow(noReflow)
            mirror.updatePaneTitle(paneId)
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
    ///
    /// Requires a live `.connected` stream — NOT just `!exited`: while
    /// reconnecting there is no stdin and `send` silently drops the command,
    /// so claiming "routed" would report success for a mutation that never
    /// reached tmux (socket callers translate `true` into an accepted reply).
    func requestSplit(windowPanelId panelId: UUID, vertical: Bool) -> Bool {
        guard connection.connectionState == .connected,
              let windowId = windowId(forPanel: panelId) else { return false }
        let targetPane = windowMirrorByWindowId[windowId]?.activePaneId
            ?? connection.windowsByID[windowId]?.paneIDsInOrder.first
        guard let targetPane else { return false }
        return connection.send("split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(targetPane)")
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
