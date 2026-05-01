import AppKit
import Bonsplit
import Combine
import Foundation

/// Observes TabManager/workspace/notification changes and pushes `workspace.sync`
/// through the single shared `DaemonConnection`. Keeps the class name so existing
/// AppDelegate / TerminalController call sites stay intact; all socket I/O is
/// owned by `DaemonConnection.shared`.
@MainActor
final class WorkspaceDaemonBridge {
    private var tabManager: TabManager?
    private var notificationStore: TerminalNotificationStore?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var panelCancellables: [UUID: AnyCancellable] = [:]
    private var panelSetCancellables: [UUID: AnyCancellable] = [:]
    private var syncIsAuthoritative = false

    private var syncScheduled = false
    private(set) var lastSyncTime: Date?
    private(set) var syncCount: Int = 0
    private var lastSentSyncFingerprint: Data?

    /// True while applying a daemon-sourced workspace.changed event. Suppresses
    /// the workspace.sync echo that observing @Published fields would otherwise
    /// trigger, preventing a ping-pong loop.
    private var applyingDaemonState = false

    /// Feature flags for Phase 2.2 field migrations. Default off. When on for
    /// a given field, the daemon owns it end-to-end: writes go via RPC, the
    /// field is excluded from workspace.sync, and incoming workspace.changed
    /// pushes are applied to local state. Flipping a flag off rolls back to
    /// the local-only behavior without redeploy.
    static let flagFieldPinned = "cmux.daemon.field.pinned"
    static let flagFieldCustomTitle = "cmux.daemon.field.customTitle"
    static let flagFieldCustomColor = "cmux.daemon.field.customColor"
    /// When on, the daemon owns workspace existence end-to-end: macOS-initiated
    /// creates/closes also fire `workspace.create` / `workspace.close` RPCs and
    /// daemon-pushed workspace.changed events add/remove local Workspace objects
    /// (deduped via DaemonConnection's pending_creates / pending_deletes).
    static let flagFieldExistence = "cmux.daemon.field.existence"

    static var pinnedOwnedByDaemon: Bool {
        UserDefaults.standard.bool(forKey: flagFieldPinned)
    }
    static var customTitleOwnedByDaemon: Bool {
        UserDefaults.standard.bool(forKey: flagFieldCustomTitle)
    }
    static var customColorOwnedByDaemon: Bool {
        UserDefaults.standard.bool(forKey: flagFieldCustomColor)
    }
    static var existenceOwnedByDaemon: Bool {
        UserDefaults.standard.bool(forKey: flagFieldExistence)
    }

    private var connection: DaemonConnection { DaemonConnection.shared }

    var isConnected: Bool { connection.isConnected }
    var statusDescription: String { connection.statusDescription }
    var socketPath: String { connection.currentSocketPath }

    init(
        authProvider: AnyObject? = nil,
        authChangePublisher: AnyPublisher<Void, Never>? = nil,
        heartbeatPublisher: AnyObject? = nil
    ) {}

    func start(tabManager: TabManager, isAuthoritative: Bool = true) {
        let isSameTabManager = self.tabManager === tabManager
        let authorityChanged = syncIsAuthoritative != isAuthoritative
        guard !isSameTabManager || authorityChanged else { return }
        self.tabManager = tabManager
        syncIsAuthoritative = isAuthoritative
        self.notificationStore = .shared
        cancellables.removeAll()
        workspaceCancellables.removeAll()
        panelCancellables.removeAll()
        panelSetCancellables.removeAll()

        connection.setWorkspaceSyncProvider { [weak self] in
            guard let self else { return nil }
            return self.buildSyncParams()
        }

        connection.setWorkspaceChangedHandler { [weak self] payload in
            DispatchQueue.main.async {
                self?.applyWorkspaceChanged(payload)
            }
        }

        tabManager.$tabs
            .sink { [weak self] workspaces in
                self?.rewireWorkspaceObservers(workspaces: workspaces)
                self?.scheduleSyncNow()
            }
            .store(in: &cancellables)

        tabManager.$selectedTabId
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSyncNow() }
            .store(in: &cancellables)

        TerminalNotificationStore.shared.$notifications
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSyncNow() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .terminalSurfaceDaemonSessionAssigned)
            .sink { [weak self] _ in self?.scheduleSyncNow() }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        workspaceCancellables.removeAll()
        panelCancellables.removeAll()
        panelSetCancellables.removeAll()
        connection.setWorkspaceChangedHandler(nil)
    }

    // MARK: - Applying daemon-sourced workspace state

    /// Apply a `workspace.changed` payload from the daemon to local Workspace
    /// objects. Each field is gated by a UserDefaults feature flag (default off)
    /// so Phase 2.2 can migrate them one at a time with rollback.
    private func applyWorkspaceChanged(_ payload: [String: Any]) {
        guard let tabManager else { return }
        guard let workspaces = payload["workspaces"] as? [[String: Any]] else { return }

        let applyPinned = Self.pinnedOwnedByDaemon
        let applyTitle = Self.customTitleOwnedByDaemon
        let applyColor = Self.customColorOwnedByDaemon
        let applyExistence = Self.existenceOwnedByDaemon
        guard applyPinned || applyTitle || applyColor || applyExistence else { return }

        let byID: [UUID: Workspace] = Dictionary(
            uniqueKeysWithValues: tabManager.tabs.compactMap { ws in (ws.id, ws) }
        )

        applyingDaemonState = true
        defer { applyingDaemonState = false }

        // Track ids the daemon currently knows about so we can reconcile both
        // pending_deletes and the local removal pass below.
        var daemonIDStrings: Set<String> = []
        var daemonUUIDs: Set<UUID> = []

        for entry in workspaces {
            guard let idString = entry["id"] as? String,
                  let id = UUID(uuidString: idString) else { continue }
            let normalizedID = id.uuidString.lowercased()
            daemonIDStrings.insert(normalizedID)
            daemonUUIDs.insert(id)

            // 1) Existence path: instantiate local Workspace if missing.
            if let ws = byID[id] {
                // If macOS-initiated this create, drop the pending entry now
                // that the daemon has acknowledged it. Field updates fall
                // through to the existing per-field handlers below.
                _ = connection.consumePendingCreate(workspaceID: id)
                applyFields(
                    to: ws,
                    entry: entry,
                    applyPinned: applyPinned,
                    applyTitle: applyTitle,
                    applyColor: applyColor
                )
            } else if applyExistence {
                // No local match. Suppress re-instantiation if we have a
                // pending close (daemon hasn't caught up yet) or if the
                // macOS app initiated a create whose echo arrived before the
                // local Workspace was inserted (rare; defensive).
                if connection.isPendingDelete(workspaceID: id) { continue }
                if connection.consumePendingCreate(workspaceID: id) { continue }

                let title = (entry["title"] as? String) ?? ""
                let directory = (entry["directory"] as? String) ?? ""
                let color = (entry["color"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedColor = (color?.isEmpty == false) ? color : nil
                let pinned = (entry["pinned"] as? Bool) ?? false
                // Daemon-originated workspaces (typical path: iOS created a
                // workspace via workspace.open_pane) carry a live pane with
                // a daemon-minted session id. Adopt it so the new mac tab
                // attaches to the running shell rather than minting a
                // second pane when createSurface calls workspace.open_pane.
                let adoptedSessionID: String? = {
                    if let panes = entry["panes"] as? [[String: Any]],
                       let first = panes.first,
                       let sid = first["session_id"] as? String,
                       !sid.isEmpty {
                        return sid
                    }
                    if let sid = entry["session_id"] as? String, !sid.isEmpty {
                        return sid
                    }
                    return nil
                }()
                tabManager.addWorkspaceFromDaemon(
                    id: id,
                    title: title,
                    directory: directory.isEmpty ? nil : directory,
                    color: normalizedColor,
                    pinned: pinned,
                    adoptedDaemonSessionID: adoptedSessionID
                )
            }
        }

        // 2) Existence path: close any local workspace the daemon no longer
        // knows about (and that we are not already trying to close locally).
        if applyExistence {
            let toClose = tabManager.tabs.filter { ws in
                !daemonUUIDs.contains(ws.id)
                    && !connection.isPendingDelete(workspaceID: ws.id)
            }
            for ws in toClose {
                tabManager.closeWorkspaceFromDaemon(ws)
            }
        }

        // 3) Reconcile pending_deletes against the daemon's current view.
        connection.reconcilePendingDeletes(currentDaemonIDs: daemonIDStrings)
    }

    private func applyFields(
        to ws: Workspace,
        entry: [String: Any],
        applyPinned: Bool,
        applyTitle: Bool,
        applyColor: Bool
    ) {
        if applyPinned, let pinned = entry["pinned"] as? Bool, ws.isPinned != pinned {
            ws.isPinned = pinned
        }
        if applyTitle, let title = entry["title"] as? String, ws.title != title {
            ws.title = title
        }
        if applyColor {
            let color = (entry["color"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (color?.isEmpty == false) ? color : nil
            if ws.customColor != normalized {
                ws.customColor = normalized
            }
        }
    }

    private func rewireWorkspaceObservers(workspaces: [Workspace]) {
        workspaceCancellables.removeAll()
        panelCancellables.removeAll()
        panelSetCancellables.removeAll()
        for workspace in workspaces {
            workspaceCancellables[workspace.id] = workspace.objectWillChange
                .sink { [weak self] _ in self?.scheduleSyncNow() }
            panelSetCancellables[workspace.id] = workspace.$panels
                .sink { [weak self] panels in
                    self?.rewirePanelObservers(panels)
                    self?.scheduleSyncNow()
                }
        }
    }

    private func rewirePanelObservers(_ panels: [UUID: any Panel]) {
        panelCancellables.removeAll()
        for panel in panels.values {
            if let terminal = panel as? TerminalPanel {
                panelCancellables[panel.id] = terminal.objectWillChange
                    .sink { [weak self] _ in self?.scheduleSyncNow() }
            }
        }
    }

    private func scheduleSyncNow() {
        guard !applyingDaemonState else { return }
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.performSync()
        }
    }

    private func performSync() {
        if Self.existenceOwnedByDaemon {
            // Daemon is source of truth for workspace existence + per-field state
            // (via workspace.create / workspace.pin / workspace.rename /
            // workspace.set_color RPCs, and OSC-parsed per-pane titles+cwd).
            // Emitting workspace.sync here would race those writes and
            // overwrite daemon-originated workspaces.
            lastSyncTime = Date()
            return
        }
        // Defer while any terminal panel is still waiting on workspace.open_pane
        // to mint its daemon session id. The daemon's syncAll rebuilds the
        // pane tree from the sync payload, so emitting a partial payload
        // mid-openPane would drop the freshly-minted pane. The openPane
        // completion posts .terminalSurfaceDaemonSessionAssigned which
        // re-kicks this sync once the id lands.
        if hasPendingDaemonSessionAssignments() {
            return
        }
        guard let params = buildSyncParams() else { return }
        guard shouldSendSync(params) else { return }
        #if DEBUG
        if let workspaces = params["workspaces"] as? [[String: Any]] {
            let summary = workspaces.map { ws -> String in
                let id = (ws["id"] as? String)?.prefix(8) ?? "?"
                let title = (ws["title"] as? String) ?? ""
                let panes = ws["panes"] as? [[String: Any]] ?? []
                let sids = panes.compactMap { $0["session_id"] as? String }
                return "\(id)[\(title)]=\(sids)"
            }.joined(separator: " ")
            dlog("sync.send.full count=\(workspaces.count) \(summary)")
        }
        #endif

        // Full sync already carries preview, phase, directory, unread, pane
        // layout, titles, pinned state, and ordering. Sending incremental
        // field RPCs immediately before the full sync multiplied daemon
        // `workspace.changed` broadcasts and could churn the persistent
        // daemon socket under split/workspace stress.
        connection.sendWorkspaceSync(params)

        lastSyncTime = Date()
        syncCount += 1
    }

    private func shouldSendSync(_ params: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(params),
              let fingerprint = try? JSONSerialization.data(
                  withJSONObject: params,
                  options: [.sortedKeys]
              ) else {
            return true
        }
        guard fingerprint != lastSentSyncFingerprint else { return false }
        lastSentSyncFingerprint = fingerprint
        return true
    }

    private func hasPendingDaemonSessionAssignments() -> Bool {
        guard let tabManager else { return false }
        let daemonRunning = MobileDaemonBridgeInline.shared.isRunning
        guard daemonRunning else { return false }
        for workspace in tabManager.tabs {
            for panel in workspace.panels.values {
                guard let terminal = panel as? TerminalPanel else { continue }
                if terminal.surface.savedDaemonSessionID != nil { continue }
                // Only count surfaces with an *active* bridge that is still
                // bootstrapping. A nil bridge means the pane is local-only
                // and will never gain a daemon session — deferring sync for
                // those would block every rename/pin/color change forever.
                // A failed bridge likewise won't produce a session.
                guard let bridge = terminal.surface.daemonBridge else { continue }
                if bridge.bootstrapFailed { continue }
                #if DEBUG
                dlog(
                    "sync.defer workspace=\(workspace.id.uuidString.prefix(8)) " +
                    "panel=\(panel.id.uuidString.prefix(8)) " +
                    "surface=\(terminal.surface.id.uuidString.prefix(8)) " +
                    "reason=daemon_session_bootstrap_in_flight"
                )
                #endif
                return true
            }
        }
        return false
    }

    private func buildSyncParams() -> [String: Any]? {
        guard let tabManager, let notificationStore else { return nil }

        let workspaces: [[String: Any]] = tabManager.tabs.map { workspace in
            let preview = workspacePreview(for: workspace)
            let terminalPanels = workspace.panels.values
                .compactMap { $0 as? TerminalPanel }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            // performSync defers while any panel is still waiting on
            // openPane, so every panel we see here has either a
            // daemon-minted id or no daemon bridge at all (release
            // builds / daemon-down). Panels without a bridge are
            // elided — they aren't daemon-visible anyway.
            let sessionIDs: [String] = terminalPanels.compactMap { panel in
                panel.surface.savedDaemonSessionID
            }
            let focusedSessionID = workspace.focusedTerminalPanel?.surface.savedDaemonSessionID
            let paneInfos: [[String: Any]] = terminalPanels.compactMap { panel in
                guard let paneSID = panel.surface.savedDaemonSessionID else { return nil }
                let customTitle = workspace.panelCustomTitles[panel.id]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = (customTitle?.isEmpty == false ? customTitle : nil)
                    ?? panel.title
                return [
                    "session_id": paneSID,
                    "title": resolvedTitle,
                    "directory": panel.directory,
                ]
            }
            var entry: [String: Any] = [
                "id": workspace.id.uuidString.lowercased(),
                "directory": workspace.currentDirectory,
                "preview": preview ?? "",
                "phase": workspace.activeRemoteTerminalSessionCount > 0 ? "active" : "idle",
                "unread_count": notificationStore.unreadCount(forTabId: workspace.id),
                "panes": paneInfos,
            ]
            if !Self.customTitleOwnedByDaemon {
                entry["title"] = workspace.title
            }
            if !Self.customColorOwnedByDaemon {
                entry["color"] = workspace.customColor ?? ""
            }
            if !Self.pinnedOwnedByDaemon {
                entry["pinned"] = workspace.isPinned
            }
            if let primarySessionID = focusedSessionID ?? sessionIDs.first {
                entry["session_id"] = primarySessionID
            }
            if sessionIDs.count > 1 {
                entry["session_ids"] = sessionIDs
            }
            entry["pane_count"] = workspace.panels.count
            return entry
        }

        return [
            "selected_workspace_id": tabManager.selectedTabId?.uuidString.lowercased() ?? "",
            "prune_sessionless_missing": syncIsAuthoritative,
            "workspaces": workspaces,
        ]
    }

    private func workspacePreview(for workspace: Workspace) -> String? {
        guard let notificationStore else { return workspace.currentDirectory }
        let notification = notificationStore.latestNotification(forTabId: workspace.id)
        for candidate in [notification?.body, notification?.subtitle, workspace.currentDirectory] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
