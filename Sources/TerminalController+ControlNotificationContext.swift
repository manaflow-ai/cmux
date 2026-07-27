import CmuxControlSocket
import Foundation

/// The notification-domain witnesses are the byte-faithful bodies of the former
/// `TerminalController.v2Notification*` dispatchers, minus the per-read
/// `v2MainSync` hop: the coordinator already runs on the main actor inside the
/// socket-command policy scope, so each hop would re-apply the identical
/// thread-local focus-allowance stack — a no-op.
///
/// `notification.create_for_caller` is intentionally NOT moved here: it has its
/// own self-contained resolver (`TerminalNotificationCallerResolver.swift`) and
/// stays on the legacy app-side dispatcher.
extension TerminalController: ControlNotificationContext {
    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationCreateResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            if let explicitSurfaceID,
               let rehomed = controlNotificationRehomedDelivery(
                   surfaceID: explicitSurfaceID, title: title, subtitle: subtitle, body: body
               ) {
                return .delivered(workspaceID: rehomed.workspaceID, surfaceID: explicitSurfaceID)
            }
            return .workspaceNotFound
        }
        if let explicitSurfaceID, ws.panels[explicitSurfaceID] == nil {
            if let rehomed = controlNotificationRehomedDelivery(
                surfaceID: explicitSurfaceID, title: title, subtitle: subtitle, body: body
            ) {
                return .delivered(workspaceID: rehomed.workspaceID, surfaceID: explicitSurfaceID)
            }
            return .surfaceNotFound(explicitSurfaceID)
        }
        let surfaceId = explicitSurfaceID ?? ws.focusedPanelId
        deliverNotificationSynchronously(
            tabId: ws.id,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return .delivered(workspaceID: ws.id, surfaceID: surfaceId)
    }

    func controlNotificationCreateForSurface(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        // Moved pane (issue #7939): a pane keeps its surface id across
        // workspace moves, so resolve the surface's CURRENT owner before
        // rejecting a claim the routing selectors no longer satisfy — whether
        // the surface left the claimed workspace or that workspace was closed.
        // `notification.create_for_surface` is NOT relay-reachable. The cloud
        // tunnel rewrites scoped `notification.create` calls to the confined
        // `create_for_target` path before they reach this trusted local path.
        guard let ws = resolveWorkspace(routing: routing, tabManager: tabManager) else {
            if let rehomed = controlNotificationRehomedDelivery(
                surfaceID: surfaceID, title: title, subtitle: subtitle, body: body
            ) {
                return .delivered(
                    workspaceID: rehomed.workspaceID, surfaceID: surfaceID, windowID: rehomed.windowID
                )
            }
            return .workspaceNotFound(workspaceID: nil)
        }
        guard ws.panels[surfaceID] != nil else {
            if let rehomed = controlNotificationRehomedDelivery(
                surfaceID: surfaceID, title: title, subtitle: subtitle, body: body
            ) {
                return .delivered(
                    workspaceID: rehomed.workspaceID, surfaceID: surfaceID, windowID: rehomed.windowID
                )
            }
            return .surfaceNotFound(surfaceID)
        }
        deliverNotificationSynchronously(
            tabId: ws.id,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return .delivered(
            workspaceID: ws.id,
            surfaceID: surfaceID,
            windowID: AppDelegate.shared?.windowId(for: tabManager)
        )
    }

    /// Shared trusted-local path for a surface that moved after its caller
    /// captured a workspace address. Relay callers are rewritten to the
    /// membership-confined `create_for_target` entrypoint before dispatch.
    private func controlNotificationRehomedDelivery(
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> (workspaceID: UUID, windowID: UUID?)? {
        guard let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID) else { return nil }
        deliverNotificationSynchronously(
            tabId: owner.workspace.id,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body
        )
        return (owner.workspace.id, AppDelegate.shared?.windowId(for: owner.tabManager))
    }

    func controlNotificationCreateForTarget(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        // SECURITY: no live re-homing here. `notification.create_for_target`
        // is reachable through the cloud relay (`RemoteDaemonProxyTunnel`),
        // whose authorization only checks that the supplied workspace_id
        // equals the relay's owner workspace — this membership guard is what
        // actually confines a VM's deliveries to its authorized workspace. A
        // global surface lookup would let a relay caller inject notifications
        // into any workspace from a leaked pane UUID. Moved-pane re-homing
        // for relayed notifications needs a trusted surface binding from the
        // relay (follow-up); trusted local callers get it via
        // `create_for_caller`/`create_for_surface`.
        guard let ws = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .workspaceNotFound(workspaceID: workspaceID)
        }
        guard ws.panels[surfaceID] != nil else {
            return .surfaceNotFound(surfaceID)
        }
        deliverNotificationSynchronously(
            tabId: ws.id,
            surfaceId: surfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            retargetsToLiveSurfaceOwner: false
        )
        return .delivered(
            workspaceID: ws.id,
            surfaceID: surfaceID,
            windowID: AppDelegate.shared?.windowId(for: tabManager)
        )
    }

    func controlNotificationList() -> [ControlNotificationSnapshot] {
        TerminalNotificationStore.shared.notifications.map { Self.controlSnapshot($0) }
    }

    func controlNotificationDismissAllRead() -> Int {
        let readIds = TerminalNotificationStore.shared.notifications
            .filter(\.isRead)
            .map(\.id)
        for id in readIds {
            TerminalNotificationStore.shared.remove(id: id)
        }
        return readIds.count
    }

    func controlNotificationDismiss(id: UUID) -> ControlNotificationDismissResolution {
        let store = TerminalNotificationStore.shared
        guard let notification = store.notifications.first(where: { $0.id == id }) else {
            return .notFound
        }
        let snapshot = Self.controlSnapshot(notification)
        store.remove(id: id)
        return .dismissed(snapshot)
    }

    func controlNotificationMarkRead(id: UUID) -> ControlNotificationMarkReadResolution {
        let store = TerminalNotificationStore.shared
        let before = store.notifications
        guard before.contains(where: { $0.id == id }) else {
            return .notFound
        }
        store.markRead(id: id)
        let afterById = Dictionary(uniqueKeysWithValues: store.notifications.map { ($0.id, $0.isRead) })
        let count = before.filter { !$0.isRead && afterById[$0.id] == true }.count
        return .marked(count: count)
    }

    func controlNotificationMarkRead(
        workspaceID: UUID,
        surfaceID: UUID?,
        hasSurfaceSelector: Bool
    ) -> Int {
        let store = TerminalNotificationStore.shared
        let before = store.notifications
        if hasSurfaceSelector {
            store.markRead(forTabId: workspaceID, surfaceId: surfaceID)
        } else {
            store.markRead(forTabId: workspaceID)
        }
        return Self.markedCount(before: before, store: store)
    }

    func controlNotificationMarkReadAll() -> Int {
        let store = TerminalNotificationStore.shared
        let before = store.notifications
        store.markAllRead()
        return Self.markedCount(before: before, store: store)
    }

    func controlNotificationOpen(id: UUID) -> ControlNotificationOpenResolution {
        let store = TerminalNotificationStore.shared
        guard let notification = store.notifications.first(where: { $0.id == id }) else {
            return .notificationNotFound
        }
        let opened = AppDelegate.shared?.openTerminalNotification(notification) ?? false
        let current = store.notifications.first(where: { $0.id == notification.id }) ?? notification
        let snapshot = Self.controlSnapshot(
            current,
            surfaceID: opened ? (current.panelId ?? current.surfaceId) : current.surfaceId
        )
        return opened ? .opened(snapshot) : .targetNotFound(snapshot)
    }

    func controlNotificationJumpToUnread() -> ControlNotificationSnapshot? {
        guard let opened = AppDelegate.shared?.jumpToLatestUnread() else { return nil }
        let store = TerminalNotificationStore.shared
        let current = store.notifications.first(where: { $0.id == opened.id }) ?? opened
        return Self.controlSnapshot(current, surfaceID: current.panelId ?? current.surfaceId)
    }

    func controlNotificationClear() {
        TerminalMutationBus.shared.enqueueClearAllNotifications()
    }

    var notificationStrings: ControlNotificationStrings {
        ControlNotificationStrings(
            dismissSelectorRequired: String(
                localized: "socket.notification.dismissSelectorRequired",
                defaultValue: "Select exactly one of id or all_read"
            ),
            idRequired: String(
                localized: "socket.notification.idRequired",
                defaultValue: "Missing or invalid notification id"
            ),
            notFound: String(
                localized: "socket.notification.notFound",
                defaultValue: "Notification not found"
            ),
            markReadSelectorRequired: String(
                localized: "socket.notification.markReadSelectorRequired",
                defaultValue: "Select exactly one of id, tab_id, or all"
            ),
            surfaceIDInvalid: String(
                localized: "socket.notification.surfaceIdInvalid",
                defaultValue: "Missing or invalid surface_id"
            ),
            surfaceIDRequiresWorkspace: String(
                localized: "socket.notification.surfaceIdRequiresWorkspace",
                defaultValue: "surface_id requires tab_id or workspace_id"
            ),
            targetNotFound: String(
                localized: "socket.notification.targetNotFound",
                defaultValue: "Notification target not found"
            )
        )
    }

    // MARK: - Resolution helpers (private, file-scoped)

    /// The routing-driven twin of the legacy `v2ResolveWorkspace(params:tabManager:)`:
    /// workspace id, then the surface set (`surface_id`/`terminal_id`/`tab_id`,
    /// already collapsed into `routing.surfaceID`), then pane, then the
    /// TabManager's selected tab.
    private func resolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID, let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// The marked-read delta the legacy bodies computed: notifications that were
    /// unread before and are read after.
    private static func markedCount(
        before: [TerminalNotification],
        store: TerminalNotificationStore
    ) -> Int {
        let afterById = Dictionary(uniqueKeysWithValues: store.notifications.map { ($0.id, $0.isRead) })
        return before.filter { !$0.isRead && afterById[$0.id] == true }.count
    }

    /// Converts a `TerminalNotification` to the Sendable snapshot, pre-rendering
    /// the ISO-8601 `created_at` and resolving the workspace tab title exactly as
    /// the legacy `notificationPayload` builder did. The date rendering mirrors
    /// the (file-private) `TerminalController.notificationCreatedAtString`.
    private static func controlSnapshot(
        _ notification: TerminalNotification,
        surfaceID: UUID? = nil
    ) -> ControlNotificationSnapshot {
        ControlNotificationSnapshot(
            id: notification.id,
            workspaceID: notification.tabId,
            surfaceID: surfaceID ?? notification.surfaceId,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAtISO8601: notificationCreatedAtISO8601(notification.createdAt),
            isRead: notification.isRead,
            tabTitle: AppDelegate.shared?.tabTitle(for: notification.tabId)
        )
    }

    /// Byte-identical reproduction of the file-private
    /// `TerminalController.notificationCreatedAtString`.
    private static func notificationCreatedAtISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
