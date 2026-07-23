import Foundation

/// Category an agent hook attaches to a notification so the app can gate
/// delivery by user config. Mirrors the CLI's `ClaudeNotifyCategory`; serialized
/// into the `notify_target_async` payload's optional legacy or ordered metadata.
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

/// Parsed agent notification metadata. Legacy two-field policy tags remain
/// valid; cmux-owned hooks add canonical `k=<status-key>;t=<event-time>` fields
/// so delivery can advance the shared per-pane ordering watermark.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentStatusKey: String?
    let agentEventTime: TimeInterval?

    init?(meta: String) {
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
        if fields.count == 2 {
            guard known != .other else { return nil }
            self.agentStatusKey = nil
            self.agentEventTime = nil
        } else {
            guard fields[2].hasPrefix("k="), fields[3].hasPrefix("t=") else { return nil }
            let statusKey = String(fields[2].dropFirst(2))
            guard !statusKey.isEmpty,
                  statusKey.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
                  let eventTime = TimeInterval(fields[3].dropFirst(2)),
                  eventTime.isFinite,
                  eventTime > 0 else { return nil }
            self.agentStatusKey = statusKey
            self.agentEventTime = eventTime
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
