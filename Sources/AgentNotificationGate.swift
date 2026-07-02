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

/// Parsed `c=<category>;p=<0|1>` meta segment. Returns `nil` unless BOTH a `c=`
/// category and a valid `p=0|1` pending flag are present, so a legacy body tail
/// that merely starts with `c=` is not mistaken for a gating directive.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool

    init?(meta: String) {
        var parsedCategory: AgentNotifyCategory? = nil
        var parsedPending: Bool? = nil
        for field in meta.split(separator: ";") {
            let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "c": parsedCategory = AgentNotifyCategory(rawValue: kv[1]) ?? .other
            case "p":
                switch kv[1] {
                case "1": parsedPending = true
                case "0": parsedPending = false
                default: return nil
                }
            default: break
            }
        }
        guard let parsedCategory, let parsedPending else { return nil }
        self.category = parsedCategory
        self.pending = parsedPending
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
