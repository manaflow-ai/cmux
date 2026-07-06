import Foundation

extension CmuxEventBus {
    func publishWorkspaceCreated(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        selected: Bool,
        index: Int?,
        tabCount: Int?
    ) {
        publish(
            name: "workspace.created",
            category: "workspace",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            payload: workspacePayload(
                workspaceId: workspaceId,
                title: title,
                customTitle: customTitle,
                currentDirectory: currentDirectory,
                selected: selected,
                index: index,
                tabCount: tabCount
            )
        )
    }

    func publishWorkspaceClosed(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        remainingTabCount: Int?
    ) {
        publish(
            name: "workspace.closed",
            category: "workspace",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            payload: workspacePayload(
                workspaceId: workspaceId,
                title: title,
                customTitle: customTitle,
                currentDirectory: currentDirectory,
                selected: false,
                index: nil,
                tabCount: remainingTabCount
            )
        )
    }

    func publishWorkspaceSelected(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        previousWorkspaceId: UUID?,
        index: Int?,
        tabCount: Int?
    ) {
        publish(
            name: "workspace.selected",
            category: "workspace",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            payload: workspacePayload(
                workspaceId: workspaceId,
                title: title,
                customTitle: customTitle,
                currentDirectory: currentDirectory,
                selected: true,
                previousWorkspaceId: previousWorkspaceId,
                index: index,
                tabCount: tabCount
            )
        )
    }

    func publishWorkspacePromptSubmitted(
        workspaceId: UUID,
        message: String?,
        preview: String?,
        source: String = "workspace.prompt_submit"
    ) {
        publish(
            name: "workspace.prompt.submitted",
            category: "workspace",
            source: source,
            workspaceId: workspaceId.uuidString,
            payload: [
                "workspace_id": workspaceId.uuidString,
                "message": NSNull(),
                "message_preview": preview ?? NSNull(),
                "message_length": message?.count ?? 0,
                "redacted_fields": ["message"]
            ]
        )
    }

    func publishWorkspaceReordered(
        workspaceIds: [UUID],
        movedWorkspaceIds: [UUID],
        pinnedWorkspaceIds: [UUID],
        source: String
    ) {
        publish(
            name: "workspace.reordered",
            category: "workspace",
            source: source,
            workspaceId: movedWorkspaceIds.first?.uuidString,
            payload: [
                "workspace_ids": workspaceIds.map(\.uuidString),
                "moved_workspace_ids": movedWorkspaceIds.map(\.uuidString),
                "pinned_workspace_ids": pinnedWorkspaceIds.map(\.uuidString),
                "count": workspaceIds.count
            ]
        )
    }

    func publishWindowLifecycle(
        name: String,
        windowId: UUID,
        workspaceId: UUID?,
        workspaceCount: Int?,
        selectedWorkspaceIndex: Int?,
        isKeyWindow: Bool?,
        isMainWindow: Bool?,
        origin: String
    ) {
        publish(
            name: name,
            category: "window",
            source: "window.lifecycle",
            workspaceId: workspaceId?.uuidString,
            windowId: windowId.uuidString,
            payload: [
                "window_id": windowId.uuidString,
                "workspace_id": workspaceId?.uuidString ?? NSNull(),
                "workspace_count": workspaceCount ?? NSNull(),
                "selected_workspace_index": selectedWorkspaceIndex ?? NSNull(),
                "is_key_window": isKeyWindow ?? NSNull(),
                "is_main_window": isMainWindow ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishPaneCreated(
        workspaceId: UUID,
        paneId: UUID,
        sourcePaneId: UUID?,
        orientation: String,
        surfaceId: UUID?,
        origin: String
    ) {
        publish(
            name: "pane.created",
            category: "pane",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId?.uuidString,
            paneId: paneId.uuidString,
            payload: [
                "pane_id": paneId.uuidString,
                "source_pane_id": sourcePaneId?.uuidString ?? NSNull(),
                "orientation": orientation,
                "surface_id": surfaceId?.uuidString ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishSurfaceCreated(
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        publish(
            name: "surface.created",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind,
                "origin": origin,
                "focused": focused
            ]
        )
    }

    func publishSurfaceSelected(
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?,
        kind: String?,
        previousSurfaceId: UUID?,
        focused: Bool,
        origin: String
    ) {
        publish(
            name: "surface.selected",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind ?? NSNull(),
                "previous_surface_id": previousSurfaceId?.uuidString ?? NSNull(),
                "focused": focused,
                "origin": origin
            ]
        )
    }

    func publishSurfaceFocused(workspaceId: UUID, surfaceId: UUID, paneId: UUID?, kind: String?, origin: String) {
        publish(
            name: "surface.focused",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishSurfaceClosed(workspaceId: UUID, surfaceId: UUID, paneId: UUID?, kind: String?, origin: String) {
        publish(
            name: "surface.closed",
            category: "surface",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            paneId: paneId?.uuidString,
            payload: [
                "surface_id": surfaceId.uuidString,
                "pane_id": paneId?.uuidString ?? NSNull(),
                "kind": kind ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishPaneClosed(workspaceId: UUID, paneId: UUID, closedSurfaceIds: [UUID], origin: String) {
        publish(
            name: "pane.closed",
            category: "pane",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            paneId: paneId.uuidString,
            payload: [
                "pane_id": paneId.uuidString,
                "closed_surface_ids": closedSurfaceIds.map(\.uuidString),
                "origin": origin
            ]
        )
    }

    func publishPaneFocused(workspaceId: UUID, paneId: UUID, selectedSurfaceId: UUID?, origin: String) {
        publish(
            name: "pane.focused",
            category: "pane",
            source: "workspace.lifecycle",
            workspaceId: workspaceId.uuidString,
            surfaceId: selectedSurfaceId?.uuidString,
            paneId: paneId.uuidString,
            payload: [
                "pane_id": paneId.uuidString,
                "selected_surface_id": selectedSurfaceId?.uuidString ?? NSNull(),
                "origin": origin
            ]
        )
    }

    func publishNotificationChanges(oldValue: [TerminalNotification], newValue: [TerminalNotification]) {
        var oldById: [UUID: TerminalNotification] = [:]
        for notification in oldValue {
#if DEBUG
            if oldById[notification.id] != nil {
                cmuxDebugLog(
                    "notification.changes.duplicateOldId function=publishNotificationChanges " +
                        "id=\(notification.id.uuidString) source=oldById " +
                        "expectedUniqueBy=TerminalNotificationStore.restoreSessionNotifications.notificationWithUniqueId"
                )
            }
#endif
            oldById[notification.id] = notification
        }
        let newIds = Set(newValue.map(\.id))
        var removedIds = Set<UUID>()
        let removed = oldValue.filter { notification in
            guard !newIds.contains(notification.id) else { return false }
            return removedIds.insert(notification.id).inserted
        }
        for notification in removed {
            publishNotificationRemoved(notification)
        }
        var seenNewIds = Set<UUID>()
        for notification in newValue {
            guard seenNewIds.insert(notification.id).inserted else { continue }
            if let old = oldById[notification.id] {
                if !old.isRead, notification.isRead {
                    publishNotificationRead(
                        ids: [notification.id.uuidString],
                        workspaceId: notification.tabId,
                        surfaceId: notification.surfaceId
                    )
                }
            } else {
                let replacedIds = removed
                    .filter { $0.tabId == notification.tabId && $0.surfaceId == notification.surfaceId }
                    .map { $0.id.uuidString }
                publishNotificationCreated(notification, delivery: "store", replacedNotificationIds: replacedIds)
            }
        }
    }

    func publishNotificationCreated(
        _ notification: TerminalNotification,
        delivery: String,
        replacedNotificationIds: [String]
    ) {
        publishNotificationLifecycle(
            name: "notification.created",
            notification: notification,
            payload: [
                "delivery": delivery,
                "replaced_notification_ids": replacedNotificationIds
            ]
        )
    }

    func publishNotificationRead(ids: [String], workspaceId: UUID?, surfaceId: UUID?) {
        guard !ids.isEmpty else { return }
        publish(
            name: "notification.read",
            category: "notification",
            source: "notification.store",
            workspaceId: workspaceId?.uuidString,
            surfaceId: surfaceId?.uuidString,
            payload: [
                "notification_ids": ids,
                "count": ids.count
            ]
        )
    }

    func publishNotificationRemoved(_ notification: TerminalNotification) {
        publishNotificationLifecycle(
            name: "notification.removed",
            notification: notification
        )
    }

    func publishNotificationCleared(ids: [String], workspaceId: UUID?, surfaceId: UUID?) {
        guard !ids.isEmpty else { return }
        publish(
            name: "notification.cleared",
            category: "notification",
            source: "notification.store",
            workspaceId: workspaceId?.uuidString,
            surfaceId: surfaceId?.uuidString,
            payload: [
                "notification_ids": ids,
                "count": ids.count
            ]
        )
    }

    private func publishNotificationLifecycle(
        name: String,
        notification: TerminalNotification,
        payload extraPayload: [String: Any] = [:]
    ) {
        var payload = CmuxSocketEventMapper.redactedNotificationParams([
            "notification_id": notification.id.uuidString,
            "workspace_id": notification.tabId.uuidString,
            "surface_id": notification.surfaceId?.uuidString ?? NSNull(),
            "title": notification.title,
            "subtitle": notification.subtitle,
            "body": notification.body,
            "created_at": notification.createdAt,
            "is_read": notification.isRead
        ])
        extraPayload.forEach { payload[$0.key] = $0.value }
        publish(
            name: name,
            category: "notification",
            source: "notification.store",
            workspaceId: notification.tabId.uuidString,
            surfaceId: notification.surfaceId?.uuidString,
            payload: payload
        )
    }

    private func workspacePayload(
        workspaceId: UUID,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        selected: Bool,
        previousWorkspaceId: UUID? = nil,
        index: Int?,
        tabCount: Int?
    ) -> [String: Any] {
        [
            "workspace_id": workspaceId.uuidString,
            "title": title,
            "custom_title": customTitle ?? NSNull(),
            "cwd": currentDirectory,
            "selected": selected,
            "previous_workspace_id": previousWorkspaceId?.uuidString ?? NSNull(),
            "index": index ?? NSNull(),
            "tab_count": tabCount ?? NSNull()
        ]
    }
}
