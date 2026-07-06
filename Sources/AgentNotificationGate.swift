import Foundation

/// Category an agent hook attaches to a notification so the app can gate
/// delivery by user config. Mirrors the CLI's `ClaudeNotifyCategory`; serialized
/// into the `notify_target_async` payload's optional meta segment.
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

/// Parsed notification meta segment. Accepted forms are exactly:
/// `c=<category>;p=<0|1>` and `c=<category>;p=<0|1>;a=<agent-id>`, where
/// `c=other` is valid only in the 3-field form (the CLI serializes
/// uncategorized agent notifications as `c=other;p=0;a=<agent-id>`). A bare
/// `a=<agent-id>` is deliberately NOT metadata: keeping the grammar to one
/// `c=`-anchored shape means a legacy body tail like "|a=prod" can never be
/// swallowed as meta. Any other string stays part of the legacy body.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentId: String?

    init?(meta: String) {
        // Accept ONLY the exact canonical serializations the CLI emits, in
        // field order, with no extras. Anything else — reordered, duplicated,
        // unknown, or trailing fields — is not metadata and stays part of the
        // legacy notification body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard (fields.count == 2 || fields.count == 3),
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))) else { return nil }
        // `.other` is never serialized without agent identity; a bare
        // `c=other;p=<x>` is not a canonical producer form, so reject it.
        if known == .other, fields.count != 3 { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        if fields.count == 3 {
            guard fields[2].hasPrefix("a="),
                  let agentId = Self.validAgentId(String(fields[2].dropFirst(2))) else { return nil }
            self.agentId = agentId
        } else {
            self.agentId = nil
        }
        self.category = known
    }

    private static func validAgentId(_ value: String) -> String? {
        guard (1...32).contains(value.count) else { return nil }
        guard value.utf8.allSatisfy({ byte in
            (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
        }) else { return nil }
        return value
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
