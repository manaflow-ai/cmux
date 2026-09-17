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

/// Parsed `c=<category>;p=<0|1>` meta segment. Returns `nil` unless BOTH a
/// KNOWN category literal and a valid `p=0|1` pending flag are present, so the
/// reserved suffix grammar is exactly the three known categories — any other
/// `c=...` tail stays part of the legacy notification body. (`.other` never
/// rides the wire: senders omit the meta entirely for ungated alerts.)
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool

    init?(meta: String) {
        // Accept ONLY the exact canonical serialization the CLI emits
        // (`c=<known-category>;p=<0|1>`, two fields, this order, no extras).
        // Anything else — reordered, duplicated, or trailing fields — is not
        // metadata and stays part of the legacy notification body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2,
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))),
              known != .other else { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        self.category = known
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
