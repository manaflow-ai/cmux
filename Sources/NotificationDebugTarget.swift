import Foundation
import UserNotifications

#if DEBUG
struct NotificationDebugTarget: Sendable {
    let workspaceId: UUID
    let surfaceId: UUID?
}

/// DEBUG-only socket adapters for `debug.notification.*` verbs, kept out of
/// the production caller resolver so debug parsing never widens production
/// visibility. Target resolution goes through the shared production seam
/// (`resolvedCallerNotificationTarget`) so the debug emitter lands on the
/// same workspace/surface a real `notification.create_for_caller` would.
@MainActor
extension TerminalController {
    func notificationDebugCallerTarget(params: [String: Any]) -> NotificationDebugTarget? {
        let preferredWorkspaceId = v2UUID(params, "preferred_workspace_id")
        let preferredSurfaceId = v2UUID(params, "preferred_surface_id")
        let callerTTY = notificationDebugStringParam(params, "caller_tty")
        let hasCallerSelector = [
            "preferred_workspace_id",
            "preferred_surface_id",
            "caller_tty",
        ].contains { key in
            guard let value = params[key] else { return false }
            return !(value is NSNull)
        }
        // Keep the long-standing synthetic-debug default explicit and outside
        // the production caller resolver. A real caller request with any
        // selector still fails closed when that selector cannot be proven.
        guard hasCallerSelector else {
            return NotificationDebugEmitter.shared.defaultTargetForDebugEmission()
        }
        // A non-null selector is an assertion about caller identity. If it is
        // malformed (or an unknown handle), reject the request rather than
        // treating it as selector-free and borrowing the focused surface.
        guard !v2HasNonNullParam(params, "preferred_workspace_id") || preferredWorkspaceId != nil,
              !v2HasNonNullParam(params, "preferred_surface_id") || preferredSurfaceId != nil,
              !v2HasNonNullParam(params, "caller_tty") || callerTTY != nil
        else { return nil }
        guard let target = resolvedCallerNotificationTarget(
            preferredWorkspaceId: preferredWorkspaceId,
            preferredSurfaceId: preferredSurfaceId,
            callerTTY: callerTTY,
            preferTTY: notificationDebugBoolParam(params, "prefer_tty") ?? false,
            preferredWorkspaceIsExplicit: true
        ) else { return nil }
        return NotificationDebugTarget(
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId
        )
    }

    func notificationDebugStringParam(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func notificationDebugBoolParam(_ params: [String: Any], _ key: String) -> Bool? {
        if let value = params[key] as? Bool { return value }
        if let value = params[key] as? NSNumber { return value.boolValue }
        switch notificationDebugStringParam(params, key)?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    /// `debug.notification.status` — the system's actual notification settings
    /// for this bundle id, so authorization/style problems are diagnosable from
    /// the socket instead of screenshot archaeology. Blocks the socket worker
    /// on the settings callback (bounded; DEBUG-only diagnostic).
    nonisolated func notificationDebugStatus() -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any] = ["available": false]
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorization: String
            switch settings.authorizationStatus {
            case .notDetermined: authorization = "notDetermined"
            case .denied: authorization = "denied"
            case .authorized: authorization = "authorized"
            case .provisional: authorization = "provisional"
            @unknown default: authorization = "unknown"
            }
            let style: String
            switch settings.alertStyle {
            case .none: style = "none"
            case .banner: style = "banner"
            case .alert: style = "alert"
            @unknown default: style = "unknown"
            }
            func setting(_ value: UNNotificationSetting) -> String {
                switch value {
                case .notSupported: return "notSupported"
                case .disabled: return "disabled"
                case .enabled: return "enabled"
                @unknown default: return "unknown"
                }
            }
            payload = [
                "available": true,
                "authorization_status": authorization,
                "alert_style": style,
                "alert_setting": setting(settings.alertSetting),
                "sound_setting": setting(settings.soundSetting),
                "badge_setting": setting(settings.badgeSetting),
                "notification_center_setting": setting(settings.notificationCenterSetting),
                "lock_screen_setting": setting(settings.lockScreenSetting),
            ]
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return payload
    }
}
#endif
