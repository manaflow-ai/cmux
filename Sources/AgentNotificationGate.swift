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

/// Parsed `c=<category>;p=<0|1>` meta segment, optionally followed by the
/// canonical `a=<approval-id>` for a needs-permission event. Returns `nil`
/// unless every field is valid, so any other `c=...` tail stays part of the
/// legacy notification body. (`.other` never rides the wire: senders omit the
/// meta entirely for ungated alerts.)
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    /// Correlates a native approval request with its completion. Only Codex
    /// approval prompts carry this optional field; legacy category metadata
    /// remains the exact two-field form.
    let approvalID: AgentApprovalCorrelationID?

    init?(meta: String) {
        // Accept ONLY the canonical serialization the CLI emits: the legacy
        // two fields, or a needs-permission record with one opaque approval
        // correlation id. Anything else stays part of the notification body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3,
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
        if fields.count == 3 {
            guard known == .needsPermission,
                  fields[2].hasPrefix("a="),
                  let approvalID = AgentApprovalCorrelationID(
                      rawValue: String(fields[2].dropFirst(2))
                  ) else {
                return nil
            }
            self.approvalID = approvalID
        } else {
            self.approvalID = nil
        }
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
