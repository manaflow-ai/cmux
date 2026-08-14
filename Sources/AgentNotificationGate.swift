import CmuxSettings
import Foundation

/// Category an agent hook attaches to a notification so the app can gate
/// delivery by user config. Mirrors the CLI's `ClaudeNotifyCategory`; serialized
/// into the `notify_target_async` payload's optional `c=<category>;p=<0|1>` meta.
enum AgentNotifyCategory: String {
    case turnComplete = "turn-complete"
    case needsPermission = "needs-permission"
    case idleReminder = "idle-reminder"
    case other

    var soundAlertType: NotificationSoundAlertType? {
        switch self {
        case .turnComplete: return .turnDone
        case .needsPermission, .idleReminder: return .needsInput
        case .other: return nil
        }
    }

    func metaSegment(
        pending: Bool,
        agentID: String,
        alertType: NotificationSoundAlertType? = nil
    ) -> String? {
        guard let resolvedAlertType = alertType ?? soundAlertType,
              let context = NotificationSoundOverrideContext(
                  agentID: agentID,
                  alertType: resolvedAlertType
              ),
              (self == .other
                ? resolvedAlertType == .errorStalled
                : soundAlertType == resolvedAlertType) else {
            return nil
        }
        return "c=\(rawValue);p=\(pending ? 1 : 0);a=\(context.agentID);s=\(context.alertType.rawValue)"
    }
}

/// User policy for the "Claude finished a turn" notification.
enum AgentTurnCompleteMode: String {
    case whenIdle
    case always
    case never
}

/// Parsed category/pending metadata, optionally carrying an agent id and alert
/// type for sound selection. Malformed tails stay part of the legacy body.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let soundContext: NotificationSoundOverrideContext?

    init?(meta: String) {
        // Accept only the canonical serialization the CLI emits: the category
        // and pending fields first, followed by the optional sound context.
        // Reordered, duplicated, or trailing fields stay in the legacy body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 4,
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))) else { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        self.category = known
        if fields.count == 2 {
            guard known != .other else { return nil }
            self.soundContext = nil
            return
        }
        guard fields[2].hasPrefix("a="), fields[3].hasPrefix("s="),
              let alertType = NotificationSoundAlertType(rawValue: String(fields[3].dropFirst(2))),
              let context = NotificationSoundOverrideContext(
                  agentID: String(fields[2].dropFirst(2)),
                  alertType: alertType
              ),
              known.soundAlertType == alertType || (known == .other && alertType == .errorStalled) else {
            return nil
        }
        self.soundContext = context
    }
}

/// Pure delivery decision for agent-tagged notifications. Kept free of any I/O
/// so it can be exhaustively unit-tested against the decision table.
nonisolated func agentNotificationShouldDeliver(
    category: AgentNotifyCategory,
    pending: Bool,
    permissionEnabled: Bool,
    turnMode: AgentTurnCompleteMode,
    idleEnabled: Bool
) -> Bool {
    switch category {
    case .needsPermission:
        return permissionEnabled
    case .turnComplete:
        switch turnMode {
        case .always: return true
        case .never: return false
        case .whenIdle: return !pending
        }
    case .idleReminder:
        return idleEnabled && !pending
    case .other:
        // Legacy/uncategorized (codex, grok, antigravity, pre-meta clients):
        // deliver exactly as before.
        return true
    }
}
