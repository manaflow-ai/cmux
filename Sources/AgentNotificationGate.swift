import CmuxControlSocket
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

/// Parsed notification metadata for delivery policy and agent ownership.
///
/// Accepted forms are the canonical `c=<category>;p=<0|1>` delivery tag, a
/// versioned `g=<envelope>` ownership tag, or both in that order. Anything
/// else stays part of the legacy notification body.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentMutationGuard: ControlSidebarAgentMutationGuard?

    init?(meta: String) {
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        if fields.count == 1, fields[0].hasPrefix("g=") {
            guard let guardValue = ControlSidebarAgentMutationGuard(
                socketEnvelope: String(fields[0].dropFirst(2))
            ) else {
                return nil
            }
            self.category = .other
            self.pending = false
            self.agentMutationGuard = guardValue
            return
        }

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
            guard fields[2].hasPrefix("g="),
                  let guardValue = ControlSidebarAgentMutationGuard(
                      socketEnvelope: String(fields[2].dropFirst(2))
                  ) else {
                return nil
            }
            self.agentMutationGuard = guardValue
        } else {
            self.agentMutationGuard = nil
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
