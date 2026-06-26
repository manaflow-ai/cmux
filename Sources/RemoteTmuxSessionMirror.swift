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
    /// Initial client-sizing retry; see ``scheduleInitialClientSizing()``.
    private var initialSizingTask: Task<Void, Never>?
    /// Re-arm the initial sizing when one of this workspace's surfaces becomes
    /// ready / enters a window: a background workspace's surfaces may not even
    /// EXIST while the rebuild-time retry runs (they are created when the
    /// workspace is first shown), so that retry alone could expire and leave the
    /// remote at ssh's default 80×24. Removed in ``detachObserver()``.
    private var surfaceReadyObservers: [NSObjectProtocol] = []

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        connection: RemoteTmuxControlConnection,
        tabManager: TabManager,
        workspace: Workspace
    ) {
        self.host = host
        self.sessionName = sessionName
        self.connection = connection
        self.tabManager = tabManager
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
            onSessionChanged: { [weak self] oldName, newName in
                self?.handleSessionNameChanged(oldName: oldName, newName: newName)
            },
            onTopologyChanged: { [weak self] in
                self?.rebuild()
            },
            onExit: { [weak self] in
                self?.handleConnectionExited()
            }
        )
        rebuild()
        installSurfaceReadinessObservers(workspaceId: workspace.id)
    }

    /// Observes surface readiness/window-attachment for this workspace and re-arms
    /// ``scheduleInitialClientSizing()`` — the sizing only succeeds once a surface
    /// is live and in a window, which for a background workspace happens long
    /// after `rebuild()`. Same observation pattern as
    /// `BackgroundWorkspacePrimeCoordinator.installReadinessObservers`.
    private func installSurfaceReadinessObservers(workspaceId: UUID) {
        let names: [Notification.Name] = [
            .terminalSurfaceDidBecomeReady, .terminalSurfaceHostedViewDidMoveToWindow,
        ]
        for name in names {
            surfaceReadyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      readyWorkspaceId == workspaceId else { return }
                Task { @MainActor in self?.scheduleInitialClientSizing() }
            })
        }
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
        panelIdByWindow.first(where: { $0.value == panelId })?.key
    }

    /// Deregisters this mirror's connection observer and tears down all per-window
    /// multi-pane renderers (called when the mirror is torn down so its callbacks
    /// don't linger on a shared connection and its pane surfaces don't leak).
    func detachObserver() {
        initialSizingTask?.cancel()
        initialSizingTask = nil
        for observer in surfaceReadyObservers { NotificationCenter.default.removeObserver(observer) }
        surfaceReadyObservers.removeAll()
        if let observerToken {
            connection.removeObserver(observerToken)
            self.observerToken = nil
        }
        for mirror in windowMirrorByWindowId.values {
            workspace?.setRemoteTmuxWindowMirror(nil, forPanelId: mirror.panelId)
            mirror.teardown()
        }
        windowMirrorByWindowId.removeAll()
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
        var createdNewPanel = false
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
                if Self.shouldSeedSinglePaneDisplay(for: window) {
                    connection.seedPane(paneId: firstPaneId)
                }
                panelId = panel.id
                createdNewPanel = true
            }
            reconcileWindowMirror(windowId: windowId, panelId: panelId, window: window, in: workspace)
        }
        if createdNewPanel { scheduleInitialClientSizing() }
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

    nonisolated static func shouldSeedSinglePaneDisplay(for window: RemoteTmuxWindow) -> Bool {
        window.paneIDsInOrder.count == 1
    }

    /// Brief retry that sizes the remote tmux client to a single-pane tab's
    /// rendered grid on attach. Needed because `createSurface` stamps the final
    /// grid before the tab is on screen, and `TerminalSurface.updateSize` only
    /// reports grid CHANGES — so without an initial push the remote would stay at
    /// ssh's default 80×24 (mangling TUIs) until the user resizes the window.
    /// This is the single-pane analogue of the multi-pane path's
    /// `RemoteTmuxWindowMirrorView.scheduleClientSize` (same shape: one synchronous
    /// attempt, then a sleep-first retry). One push from the first on-screen
    /// surface suffices (the tmux client has a single size); live resizes
    /// afterwards flow through the panel's `onResize` hook. Re-armed by the
    /// surface-readiness observers whenever a surface becomes displayable, so a
    /// background workspace is sized when first shown even though this retry
    /// budget expired long before.
    private func scheduleInitialClientSizing() {
        initialSizingTask?.cancel()
        if pushInitialClientSize() { return }
        initialSizingTask = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                guard let self else { return }
                if self.pushInitialClientSize() { return }
            }
        }
    }

    /// One initial-sizing attempt. Returns `true` when there is nothing (more) to
    /// do: the size was pushed from the first single-pane surface with an
    /// on-screen grid, or no single-pane window remains to size (multi-pane
    /// windows are skipped — their mirror view owns client sizing).
    private func pushInitialClientSize() -> Bool {
        guard let workspace else { return true }
        let singlePanePanelIds = panelIdByWindow
            .filter { windowMirrorByWindowId[$0.key] == nil }
            .values
        guard !singlePanePanelIds.isEmpty else { return true }
        for panelId in singlePanePanelIds {
            guard let panel = workspace.panels[panelId] as? TerminalPanel,
                  let grid = panel.surface.renderedGridCells() else { continue }
            connection.setClientSize(columns: grid.columns, rows: grid.rows)
            return true
        }
        return false
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
            paneTintDefaults: workspace.terminalSplitPaneTintDefaults,
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

    /// Computes the target tab order for a remote-tmux-driven reorder, or `nil`
    /// when no reorder is needed or safe. Pure helper called by
    /// `Workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder:)`.
    ///
    /// - Parameters:
    ///   - current: the workspace's current mirror-tab order (panel ids).
    ///   - requested: the tmux window order mapped to panel ids.
    /// - Returns: the new order to apply, or `nil` when the tabs already match
    ///   `requested` or when `requested` (restricted to currently-present tabs) is
    ///   not a permutation of `current` (sets diverge — leave the tabs untouched).
    nonisolated static func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? {
        let present = Set(current)
        let desired = requested.filter { present.contains($0) }
        guard desired.count == current.count, Set(desired) == present else { return nil }
        return desired == current ? nil : desired
    }
}
