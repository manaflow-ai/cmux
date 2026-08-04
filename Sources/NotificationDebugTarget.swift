import Foundation

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
        guard let target = resolvedCallerNotificationTarget(
            preferredWorkspaceId: v2UUID(params, "preferred_workspace_id"),
            preferredSurfaceId: v2UUID(params, "preferred_surface_id"),
            callerTTY: notificationDebugStringParam(params, "caller_tty"),
            preferTTY: notificationDebugBoolParam(params, "prefer_tty") ?? false
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
}
#endif
