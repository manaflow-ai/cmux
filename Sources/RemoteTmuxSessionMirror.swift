import AppKit
import Bonsplit
import CmuxTerminal
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

    /// Sizing introspection for every mirrored window (see
    /// ``RemoteTmuxWindowMirror/sizingSnapshot()``), ordered by window id.
    func sizingSnapshots() -> [RemoteTmuxWindowMirror.SizingSnapshot] {
        windowMirrorByWindowId.keys.sorted()
            .compactMap { windowMirrorByWindowId[$0]?.sizingSnapshot() }
    }

    /// Every mirrored tmux pane paired with the cmux surface rendering it,
    /// ordered by window then pane. Every window owns a mirror from its initial
    /// one-pane layout, so every pane has one stable mirror-owned surface.
    /// Backs `remote.tmux.pane_surfaces`.
    func paneSurfaceEntries() -> [[String: Any]] {
        // `windowIdByPane` is the session's authoritative ownership (mirrored from
        // the connection's published map, which drops a window's stale panes when
        // that window republishes). Attribute every pane through it, and key the
        // result BY PANE: a `join-pane`/`swap-pane` in flight can leave the source
        // window still holding the pane in its own mirror until its reconcile runs,
        // so scanning published trees would report the pane twice — or pick the
        // stale window's frozen surface, whichever came first in dictionary order.
        var byPane: [Int: (windowId: Int, surfaceId: UUID, onScreen: Bool)] = [:]
        for (windowId, mirror) in windowMirrorByWindowId {
            for (paneId, panel) in mirror.panelsByPaneId
            where windowIdByPane[paneId] == windowId {
                byPane[paneId] = (windowId, panel.id, Self.isOnScreen(panel))
            }
        }
        return byPane
            .map { paneId, entry in
                (windowId: entry.windowId, paneId: paneId,
                 surfaceId: entry.surfaceId, onScreen: entry.onScreen)
            }
            .sorted { ($0.windowId, $0.paneId) < ($1.windowId, $1.paneId) }
            .map { [
                "window_id": "@\($0.windowId)",
                "pane_id": "%\($0.paneId)",
                "surface_id": $0.surfaceId.uuidString,
                // Only an on-screen pane's content is required to match tmux:
                // a hidden tab holds its last render by design and catches up
                // when selected, so a content oracle must skip it rather than
                // report a designed lag as a mismatch.
                "on_screen": $0.onScreen,
            ] }
    }

    /// Whether a pane's hosted view is actually presented — the same predicate
    /// ``RemoteTmuxWindowMirror/isEffectivelyVisibleForSizing`` judges with.
    private static func isOnScreen(_ panel: TerminalPanel) -> Bool {
        let view = panel.hostedView
        return view.isVisibleInUI
            && !view.isHidden
            && view.superview != nil
            && view.window?.isVisible == true
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
    var windowIdByPane: [Int: Int] = [:]
    var controlPaneIdByPane: [Int: PaneID] = [:]
    var controlSurfaceIdByPane: [Int: UUID] = [:]
    var tmuxPaneIdByControlSurface: [UUID: Int] = [:]
    /// Last-known working directory per tmux pane, so switching the active pane
    /// can re-project that pane's directory onto the tab.
    var cwdByPane: [Int: String] = [:]
    /// Per-pane filter that strips the screen/tmux `ESC k <title> ST` window-title
    /// escape from `%output` (stateful across chunk boundaries).
    var titleFilters: [Int: RemoteTmuxScreenTitleFilter] = [:]
    /// Per-pane filter that intercepts OSC 777/9 desktop-notification escapes
    /// from `%output` (stateful across chunk boundaries) so a remote process
    /// inside the mirrored session can notify locally (issue #833).
    var notificationFilters: [Int: RemoteTmuxNotificationOSCFilter] = [:]
    /// Authoritative seed bytes waiting for Ghostty's terminal grid to consume
    /// the pane's published dimensions. Surface sizing APIs expose the requested
    /// grid before Ghostty's I/O thread applies it, so seed delivery cannot use
    /// those APIs as its readiness boundary.
    var pendingPaneSeedBytes: [Int: Data] = [:]
    /// Cleaned live output received after a gated seed, retained in stream order.
    var pendingPaneSeedLiveOutput: [Int: [Data]] = [:]
    /// Published pane grid each gated seed must observe in the terminal-locked
    /// render-grid export before delivery.
    var pendingPaneSeedTargetGrids: [Int: (columns: Int, rows: Int)] = [:]
    /// Delivery kind determines whether a later visible repaint may replace the
    /// pending bytes or must follow a full-history snapshot.
    var pendingPaneSeedKinds: [Int: RemoteTmuxPaneSeedKind] = [:]
    /// Total retained seed plus live-output bytes per pane.
    var pendingPaneSeedByteCounts: [Int: Int] = [:]
    /// Aggregate retained consumer bytes across every pane in this mirror.
    var pendingPaneSeedTotalByteCount = 0
    let pendingPaneSeedByteLimit: Int
    /// Per-pane expiry drops retained bytes if a surface never reaches its target grid.
    var pendingPaneSeedDeadlineTasks: [Int: Task<Void, Never>] = [:]
    /// Generation token preventing a canceled older deadline from expiring its replacement.
    var pendingPaneSeedDeadlineIDs: [Int: UUID] = [:]
    /// Panes whose expired delivery needs one fresh full seed after a later ready frame.
    var deferredFullPaneReseeds: Set<Int> = []
    /// Pane-local frame demand stays retained until this pane renders or leaves.
    var paneSeedFrameDemandReleases: [Int: () -> Void] = [:]
    var paneSeedFrameObserverTokens: [Int: NSObjectProtocol] = [:]
    /// Ghostty readiness observers are retained only while a pane waits.
    var paneSeedReadinessObserverTokens: [NSObjectProtocol] = []
    /// Per-window renderers, created from each window's first published layout.
    var windowMirrorByWindowId: [Int: RemoteTmuxWindowMirror] = [:]
    private var pendingExplicitFocusWindowId: Int?
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?
    private var paneInputForwarder: RemoteTmuxPaneInputForwarder?

    /// Snapshots the session's ordered input seam for a Ghostty I/O callback.
    func makePaneInputHandler(
        toPane paneID: Int
    ) -> (@Sendable (TerminalManualInput) -> Void)? {
        guard let paneInputForwarder else { return nil }
        return { input in
            paneInputForwarder.send(input, toPane: paneID)
        }
    }

    init(
        host: RemoteTmuxHost,
        sessionName: String,
        seededSessionId: Int? = nil,
        connection: RemoteTmuxControlConnection,
        tabManager: TabManager,
        workspace: Workspace,
        pendingPaneSeedByteLimit: Int = RemoteTmuxControlConnection.maximumPendingPaneSeedBytes,
        onControlPaneRemoved: @escaping (PaneID, UUID?) -> Void = { _, _ in },
        onControlSurfaceRemoved: @escaping (UUID) -> Void = { _ in }
    ) {
        self.host = host
        self.sessionName = sessionName
        self.seededSessionId = seededSessionId
        self.connection = connection
        self.pendingPaneSeedByteLimit = max(0, pendingPaneSeedByteLimit)
        self.onControlPaneRemoved = onControlPaneRemoved
        self.onControlSurfaceRemoved = onControlSurfaceRemoved
        self.tabManager = tabManager
        self.workspace = workspace
        self.defaultPanelIds = Array(workspace.panels.keys)
        workspace.remoteTmuxSessionMirror = self
        self.paneInputForwarder = RemoteTmuxPaneInputForwarder(
            isActive: connection.connectionState == .connected,
            onInput: { [weak self] input, paneID in
                self?.sendManualInput(input, toPane: paneID)
            },
            onOverflow: { [weak self] in
                guard let self else { return }
                self.connection.record("manual-input-backpressure")
                self.connection.beginReconnecting()
            }
        )

        // Register as one of possibly several observers — never overwrite a
        // single shared closure on the connection.
        self.observerToken = connection.addObserver(
            onPaneOutput: { [weak self] paneId, data in
                self?.routeOutput(paneId: paneId, data: data)
            },
            onPaneSeed: { [weak self] paneId, seed in
                self?.routeSeed(paneId: paneId, seed: seed)
            },
            onPaneCwd: { [weak self] paneId, path in
                self?.handlePaneCwd(paneId: paneId, path: path)
            },
            onPaneReflow: { [weak self] paneId, noReflow in
                self?.routeNoReflow(paneId: paneId, noReflow: noReflow)
            },
            onPaneTitleChanged: { [weak self] paneId in
                self?.handlePaneTitleChanged(paneId: paneId)
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
                self?.paneInputForwarder?.setConnectionActive(state == .connected)
                // Drop any mid-`ESC k` title-filter state when the stream isn't live:
                // a reconnect's `reseedAfterReconnect` re-emits clear/capture bytes,
                // and a filter stuck mid-title from before the drop would swallow them.
                // Resetting on the disconnect edge is ordering-independent (no output
                // arrives while not connected).
                if state != .connected {
                    self?.titleFilters.removeAll()
                    self?.notificationFilters.removeAll()
                    self?.clearPendingPaneSeedDeliveries()
                    self?.windowMirrorByWindowId.values.forEach {
                        $0.cancelPendingControlPaneFocus()
                    }
                }
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
    /// renderers (called when the mirror is torn down so its callbacks
    /// don't linger on a shared connection and its pane surfaces don't leak).
    func detachObserver() {
        clearPendingPaneSeedDeliveries()
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
    func windowIdContaining(pane paneId: Int) -> Int? {
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
            if let existing = panelIdByWindow[windowId] {
                // Existing tab — refresh its title if tmux renamed the window.
                workspace.updateRemoteTmuxTabTitle(panelId: existing, title: title)
                panelId = existing
            } else {
                guard let panel = workspace.addRemoteTmuxDisplayPane(
                    remotePaneId: firstPaneId,
                    title: title,
                    focus: false,
                    // The workspace panel is only the stable window container.
                    // Its runtime is retired as soon as the window mirror below
                    // creates the real pane surface, even for a one-pane window.
                    onInput: { _ in }
                ) else { continue }
                panelIdByWindow[windowId] = panel.id
                windowIdByPanel[panel.id] = windowId
                panelId = panel.id
            }
            reconcileWindowMirror(
                windowId: windowId,
                panelId: panelId,
                window: window,
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
        cwdByPane = cwdByPane.filter { livePanes.contains($0.key) }
        titleFilters = titleFilters.filter { livePanes.contains($0.key) }
        reconcilePendingPaneSeedDeliveries(keeping: Set(windowIdByPane.keys))
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

    /// Routes a pane's reported working directory to the tab that renders it. The
    /// window tab updates only when the reporting pane is active, so a
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
        // Only the active pane represents the window tab.
        if let windowId = windowIdContaining(pane: paneId),
           windowMirrorByWindowId[windowId] != nil,
           activePane(inWindow: windowId) != paneId {
            return
        }
        _ = workspace.updateRemotePanelDirectoryWithMetadata(panelId: panelId, directory: trimmed)
    }

    /// Re-projects the newly-active pane's cached directory onto its
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

    /// The workspace-owned container panel id of the tab that renders `paneId`.
    private func tabPanelId(forPane paneId: Int) -> UUID? {
        windowIdContaining(pane: paneId).flatMap { panelIdByWindow[$0] }
    }

    /// The pane that currently represents `windowId`'s tab: the user-focused mirror
    /// pane, else tmux's active pane, else the window's first pane.
    private func activePane(inWindow windowId: Int) -> Int? {
        windowMirrorByWindowId[windowId]?.activePaneId
            ?? connection.activePaneByWindow[windowId]
            ?? connection.windowsByID[windowId]?.paneIDsInOrder.first
    }

    /// Applies a pane's reflow classification to its mirror surface (suppress
    /// reflow on resize for alt-screen / inline-TUI panes; allow it for shells).
    /// Routes exactly like ``routeOutput(paneId:data:)`` through the window mirror.
    private func routeNoReflow(paneId: Int, noReflow: Bool) {
        guard let windowId = windowIdContaining(pane: paneId),
              let mirror = windowMirrorByWindowId[windowId] else { return }
        mirror.surface(forPane: paneId)?.setManualIONoReflow(noReflow)
        mirror.updatePaneTitle(paneId)
    }

    /// Updates only the mirror-owned tab for a pane whose tmux title changed.
    /// Title events do not alter topology, so rebuilding every window here would
    /// turn a single-pane retitle into a session-wide reconciliation.
    private func handlePaneTitleChanged(paneId: Int) {
        guard let windowId = windowIdContaining(pane: paneId),
              let mirror = windowMirrorByWindowId[windowId] else { return }
        mirror.updatePaneTitleMetadata(paneId)
    }

    /// Whether `surfaceId` is one of this session mirror's pane surfaces. Used to route
    /// a pasted image to this mirror's tmux host for SSH upload.
    func ownsSurface(_ surfaceId: UUID) -> Bool {
        paneId(forSurfaceId: surfaceId) != nil
    }

    /// The tmux pane id whose mirror-owned surface is `surfaceId`, or nil if this
    /// session mirror doesn't render it.
    /// Used to target a tmux paste at the pane behind a cmux surface.
    func paneId(forSurfaceId surfaceId: UUID) -> Int? {
        windowMirror(forSurfaceId: surfaceId)?.tmuxPaneId
    }

    /// The window renderer + tmux pane id for a focused mirror surface, used
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
