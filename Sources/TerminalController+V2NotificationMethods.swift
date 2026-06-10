import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 notification, feedback, and settings methods
extension TerminalController {
    func v2NotificationCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let explicitSurfaceId = v2UUID(params, "surface_id")
        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let explicitSurfaceId, ws.panels[explicitSurfaceId] == nil {
                result = .err(
                    code: "not_found",
                    message: "Surface not found",
                    data: ["surface_id": explicitSurfaceId.uuidString]
                )
                return
            }
            let surfaceId = explicitSurfaceId ?? ws.focusedPanelId
            deliverNotificationSynchronously(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "surface_id": v2OrNull(surfaceId?.uuidString)])
        }
        return result
    }

    func v2NotificationCreateForSurface(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            deliverNotificationSynchronously(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    func v2NotificationCreateForTarget(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = tabManager.tabs.first(where: { $0.id == wsId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            deliverNotificationSynchronously(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    func v2NotificationList() -> [String: Any] {
        var items: [[String: Any]] = []
        v2MainSync {
            items = TerminalNotificationStore.shared.notifications.map { n in
                return notificationPayload(n, opened: nil, includeReadState: true)
            }
        }
        return ["notifications": items]
    }

    func v2NotificationDismiss(params: [String: Any]) -> V2CallResult {
        let id = v2UUID(params, "id")
        let allRead = v2Bool(params, "all_read") ?? false
        let selectorCount = (id == nil ? 0 : 1) + (allRead ? 1 : 0)

        guard selectorCount == 1 else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.notification.dismissSelectorRequired", defaultValue: "Select exactly one of id or all_read"),
                data: nil
            )
        }

        if allRead {
            var dismissedCount = 0
            v2MainSync {
                let readIds = TerminalNotificationStore.shared.notifications
                    .filter(\.isRead)
                    .map(\.id)
                for id in readIds {
                    TerminalNotificationStore.shared.remove(id: id)
                }
                dismissedCount = readIds.count
            }
            return .ok(["dismissed": dismissedCount, "all_read": true])
        }

        guard let id else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.notification.idRequired", defaultValue: "Missing or invalid notification id"),
                data: nil
            )
        }

        var dismissed = false
        var payload: [String: Any] = [:]
        v2MainSync {
            let notification = TerminalNotificationStore.shared.notifications.first(where: { $0.id == id })
            if let notification {
                payload = notificationPayload(notification, opened: nil, includeReadState: true)
                TerminalNotificationStore.shared.remove(id: id)
                dismissed = true
            }
        }
        guard dismissed else {
            return .err(
                code: "not_found",
                message: String(localized: "socket.notification.notFound", defaultValue: "Notification not found"),
                data: ["id": id.uuidString]
            )
        }
        payload["dismissed"] = 1
        return .ok(payload)
    }

    func v2NotificationMarkRead(params: [String: Any]) -> V2CallResult {
        let id = v2UUID(params, "id")
        let tabId = v2UUID(params, "tab_id") ?? v2UUID(params, "workspace_id")
        let hasSurfaceSelector = v2HasNonNullParam(params, "surface_id")
        let surfaceId = v2UUID(params, "surface_id")
        let all = v2Bool(params, "all") ?? false
        let selectorCount = (id == nil ? 0 : 1) + (tabId == nil ? 0 : 1) + (all ? 1 : 0)

        guard selectorCount == 1 else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.notification.markReadSelectorRequired", defaultValue: "Select exactly one of id, tab_id, or all"),
                data: nil
            )
        }
        if hasSurfaceSelector, surfaceId == nil {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.notification.surfaceIdInvalid", defaultValue: "Missing or invalid surface_id"),
                data: nil
            )
        }
        if hasSurfaceSelector, tabId == nil {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.notification.surfaceIdRequiresWorkspace", defaultValue: "surface_id requires tab_id or workspace_id"),
                data: nil
            )
        }

        var markedCount = 0
        var selectedNotificationExists = true
        v2MainSync {
            let store = TerminalNotificationStore.shared
            let before = store.notifications
            if let id {
                guard before.contains(where: { $0.id == id }) else {
                    selectedNotificationExists = false
                    return
                }
                store.markRead(id: id)
            } else if let tabId {
                if hasSurfaceSelector {
                    store.markRead(forTabId: tabId, surfaceId: surfaceId)
                } else {
                    store.markRead(forTabId: tabId)
                }
            } else if all {
                store.markAllRead()
            }
            let afterById = Dictionary(uniqueKeysWithValues: store.notifications.map { ($0.id, $0.isRead) })
            markedCount = before.filter { !$0.isRead && afterById[$0.id] == true }.count
        }

        if !selectedNotificationExists, let id {
            return .err(
                code: "not_found",
                message: String(localized: "socket.notification.notFound", defaultValue: "Notification not found"),
                data: ["id": id.uuidString]
            )
        }

        var result: [String: Any] = ["marked_read": markedCount]
        if let id { result["id"] = id.uuidString }
        if let tabId {
            result["workspace_id"] = tabId.uuidString
            result["workspace_ref"] = v2Ref(kind: .workspace, uuid: tabId)
        }
        if hasSurfaceSelector {
            result["surface_id"] = v2OrNull(surfaceId?.uuidString)
            result["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
        }
        if all { result["all"] = true }
        return .ok(result)
    }

    func v2NotificationOpen(params: [String: Any]) -> V2CallResult {
        guard let id = v2UUID(params, "id") else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.notification.idRequired", defaultValue: "Missing or invalid notification id"),
                data: nil
            )
        }

        var notification: TerminalNotification?
        var opened = false
        var payload: [String: Any] = [:]
        v2MainSync {
            let store = TerminalNotificationStore.shared
            notification = store.notifications.first(where: { $0.id == id })
            if let notification {
                opened = AppDelegate.shared?.openTerminalNotification(notification) ?? false
                let current = store.notifications.first(where: { $0.id == notification.id }) ?? notification
                payload = notificationPayload(current, opened: opened, includeReadState: true)
            }
        }

        guard notification != nil else {
            return .err(
                code: "not_found",
                message: String(localized: "socket.notification.notFound", defaultValue: "Notification not found"),
                data: ["id": id.uuidString]
            )
        }
        guard opened else {
            return .err(
                code: "not_found",
                message: String(localized: "socket.notification.targetNotFound", defaultValue: "Notification target not found"),
                data: payload
            )
        }
        return .ok(payload)
    }

    func v2NotificationJumpToUnread() -> V2CallResult {
        var openedNotification: TerminalNotification?
        var payload: [String: Any] = [:]
        v2MainSync {
            openedNotification = AppDelegate.shared?.jumpToLatestUnread()
            if let openedNotification {
                let store = TerminalNotificationStore.shared
                let current = store.notifications.first(where: { $0.id == openedNotification.id }) ?? openedNotification
                payload = notificationPayload(current, opened: true, includeReadState: true)
            }
        }
        guard openedNotification != nil else {
            return .ok(["opened": false])
        }
        return .ok(payload)
    }

    private func notificationPayload(
        _ notification: TerminalNotification,
        opened: Bool?,
        includeReadState: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": notification.id.uuidString,
            "workspace_id": notification.tabId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: notification.tabId),
            "surface_id": v2OrNull(notification.surfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: notification.surfaceId),
            "title": notification.title,
            "subtitle": notification.subtitle,
            "body": notification.body,
            "created_at": Self.notificationCreatedAtString(notification.createdAt),
            "tab_title": v2OrNull(AppDelegate.shared?.tabTitle(for: notification.tabId)),
        ]
        if includeReadState {
            payload["is_read"] = notification.isRead
        }
        if let opened {
            payload["opened"] = opened
        }
        return payload
    }

    func v2NotificationClear() -> V2CallResult {
        TerminalMutationBus.shared.enqueueClearAllNotifications()
        return .ok([:])
    }

    func v2FeedbackOpen(params: [String: Any]) -> V2CallResult {
        let workspaceId = v2UUID(params, "workspace_id")
        let windowId = v2UUID(params, "window_id")
        let shouldActivate = v2FocusAllowed(requested: v2Bool(params, "activate") ?? false)
        DispatchQueue.main.async {
            let targetWindow: NSWindow?
            if let windowId, let app = AppDelegate.shared {
                targetWindow = app.mainWindow(for: windowId)
            } else if let workspaceId, let app = AppDelegate.shared {
                targetWindow = app.mainWindowContainingWorkspace(workspaceId)
            } else {
                targetWindow = nil
            }

            if shouldActivate {
                if let targetWindow {
                    _ = AppDelegate.shared?.focusWindowForAppActivation(targetWindow, reason: .feedback)
                } else {
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            }

            FeedbackComposerBridge.openComposer(in: targetWindow)
        }
        return .ok(["opened": true])
    }

    func v2SessionRestorePrevious() -> V2CallResult {
        var restored = false
        v2MainSync {
            restored = AppDelegate.shared?.reopenPreviousSession(shouldActivate: false) ?? false
        }
        guard restored else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "terminal.restore.no_snapshot",
                    defaultValue: "No previous session snapshot available"
                ),
                data: nil
            )
        }
        return .ok(["restored": true])
    }

    func v2SettingsOpen(params: [String: Any]) -> V2CallResult {
        let targetRaw = v2String(params, "target")
        let shouldActivate = v2FocusAllowed(requested: v2Bool(params, "activate") ?? true)

        let navigationTarget: SettingsNavigationTarget?
        if let targetRaw {
            guard let target = SettingsNavigationTarget(rawValue: targetRaw) else {
                return .err(code: "invalid_params", message: "Unknown settings target", data: ["target": targetRaw])
            }
            navigationTarget = target
        } else {
            navigationTarget = nil
        }

        DispatchQueue.main.async {
            if shouldActivate {
                AppDelegate.presentPreferencesWindow(navigationTarget: navigationTarget)
            } else {
                SettingsWindowPresenter.show(navigationTarget: navigationTarget)
            }
        }
        return .ok([
            "opened": true,
            "target": navigationTarget?.rawValue ?? "general",
        ])
    }

    nonisolated func v2FeedbackSubmit(params: [String: Any]) -> V2CallResult {
        guard let email = params["email"] as? String else {
            return .err(code: "invalid_params", message: "Missing email", data: ["field": "email"])
        }
        guard let body = params["body"] as? String else {
            return .err(code: "invalid_params", message: "Missing body", data: ["field": "body"])
        }
        let imagePaths = params["image_paths"] as? [String] ?? []

        let semaphore = DispatchSemaphore(value: 0)
        var result: V2CallResult = .err(code: "internal_error", message: "Feedback submission failed", data: nil)

        Task {
            let resolved: V2CallResult
            do {
                let attachmentCount = try await FeedbackComposerBridge.submit(
                    email: email,
                    message: body,
                    imagePaths: imagePaths
                )
                resolved = .ok([
                    "submitted": true,
                    "attachment_count": attachmentCount,
                ])
            } catch let error as FeedbackComposerBridgeError {
                let code: String
                switch error {
                case .invalidEmail, .emptyMessage, .messageTooLong, .tooManyImages, .invalidImagePath:
                    code = "invalid_params"
                case .submissionFailed:
                    code = "request_failed"
                }
                resolved = .err(code: code, message: error.localizedDescription, data: nil)
            } catch {
                resolved = .err(code: "internal_error", message: error.localizedDescription, data: nil)
            }

            result = resolved
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .err(code: "timeout", message: "Feedback submission timed out", data: nil)
        }

        return result
    }

    // MARK: - V2 Feed (workstream) handlers

}
