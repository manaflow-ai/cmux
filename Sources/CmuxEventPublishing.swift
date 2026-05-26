import Foundation
import CMUXWorkstream

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
        let oldById = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0) })
        let newIds = Set(newValue.map(\.id))
        let removed = oldValue.filter { !newIds.contains($0.id) }
        for notification in removed {
            publishNotificationRemoved(notification)
        }
        for notification in newValue {
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

    // swiftlint:disable:next discouraged_optional_collection
    func publishWorkstreamEvent(_ event: WorkstreamEvent, phase: String, result: [String: Any]? = nil) {
        var payload = Self.workstreamPayload(event)
        payload["phase"] = phase
        if let result {
            payload["result"] = result
        }

        publish(
            name: "agent.hook.\(event.hookEventName.rawValue)",
            category: "agent",
            source: event.source,
            workspaceId: event.workspaceId,
            payload: payload
        )

        publish(
            name: "feed.item.\(phase)",
            category: "feed",
            source: event.source,
            workspaceId: event.workspaceId,
            payload: payload
        )
    }

    static func workstreamPayload(_ event: WorkstreamEvent) -> [String: Any] {
        var payload: [String: Any] = [
            "session_id": event.sessionId,
            "hook_event_name": event.hookEventName.rawValue,
            "_source": event.source,
            "workspace_id": event.workspaceId ?? NSNull(),
            "cwd": event.cwd ?? NSNull(),
            "tool_name": event.toolName ?? NSNull(),
            "_opencode_request_id": event.requestId ?? NSNull(),
            "_ppid": event.ppid ?? NSNull(),
            "_received_at": Self.isoTimestamp(event.receivedAt)
        ]
        var redactedFields: [String] = []
        if let toolInputJSON = event.toolInputJSON {
            payload["tool_input"] = NSNull()
            payload["tool_input_length"] = toolInputJSON.count
            redactedFields.append("tool_input")
        }
        if let context = event.context, !context.isEmpty {
            payload["context"] = NSNull()
            if let contextLength = encodedByteCount(context) {
                payload["context_length"] = contextLength
            }
            redactedFields.append("context")
        }
        if let extraFieldsJSON = event.extraFieldsJSON {
            payload["extra_fields"] = NSNull()
            payload["extra_fields_length"] = extraFieldsJSON.count
            redactedFields.append("extra_fields")
        }
        if !redactedFields.isEmpty {
            payload["redacted_fields"] = redactedFields
        }
        return payload
    }

    private static func encodedByteCount<T: Encodable>(_ value: T) -> Int? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value).count
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
