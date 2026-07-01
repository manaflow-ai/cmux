import Foundation

/// Category an agent hook attaches to a notification so the app can gate
/// delivery by user config. Mirrors the CLI's `ClaudeNotifyCategory`; serialized
/// into the `notify_target_async` payload's optional `c=<category>;p=<0|1>` meta.
enum AgentNotifyCategory: String {
    case turnComplete = "turn-complete"
    case needsPermission = "needs-permission"
    case idleReminder = "idle-reminder"
    case other
}

/// User policy for the "Claude finished a turn" notification.
enum AgentTurnCompleteMode: String {
    case whenIdle
    case always
    case never
}

/// Parsed `c=<category>;p=<0|1>` meta segment. `nil` when the segment is not our
/// grammar (a legacy body that happened to survive the `c=` guard upstream).
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool

    init?(meta: String) {
        var parsedCategory: AgentNotifyCategory? = nil
        var parsedPending = false
        for field in meta.split(separator: ";") {
            let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "c": parsedCategory = AgentNotifyCategory(rawValue: kv[1]) ?? .other
            case "p": parsedPending = kv[1] == "1"
            default: break
            }
        }
        guard let parsedCategory else { return nil }
        self.category = parsedCategory
        self.pending = parsedPending
    }
}

/// Pure delivery decision for agent-tagged notifications. Kept free of any I/O
/// so it can be exhaustively unit-tested against the decision table.
enum AgentNotificationGate {
    static func shouldDeliver(
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
}
