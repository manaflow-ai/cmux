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

/// Parsed notification metadata for delivery policy, agent context, and
/// apply-time ownership. Canonical fields are `c=...;p=0|1`, followed by
/// optional `a=`, `n=`, `k=`, and a final `g=` guard. A guard-only `g=` form is
/// accepted for uncategorized notifications.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentKind: String?
    let isSubagent: Bool?
    let correlationKey: String?
    let agentMutationGuard: ControlSidebarAgentMutationGuard?

    init?(meta: String) {
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        if fields.count == 1, fields[0].hasPrefix("g=") {
            guard let guardValue = ControlSidebarAgentMutationGuard(
                socketEnvelope: String(fields[0].dropFirst(2))
            ) else { return nil }
            category = .other
            pending = false
            agentKind = nil
            isSubagent = nil
            correlationKey = nil
            agentMutationGuard = guardValue
            return
        }

        // Canonical category metadata permits a, n, k, and g in that order.
        guard (2...6).contains(fields.count),
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))),
              known != .other else { return nil }
        let parsedPending: Bool
        switch fields[1].dropFirst(2) {
        case "1": parsedPending = true
        case "0": parsedPending = false
        default: return nil
        }
        var parsedAgentKind: String?
        var parsedIsSubagent: Bool?
        var parsedCorrelationKey: String?
        var parsedGuard: ControlSidebarAgentMutationGuard?
        var index = 2
        if index < fields.count, fields[index].hasPrefix("a=") {
            let kind = String(fields[index].dropFirst(2))
            guard Self.isValidAgentKindTag(kind) else { return nil }
            parsedAgentKind = kind
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("n=") {
            switch fields[index].dropFirst(2) {
            case "1": parsedIsSubagent = true
            case "0": parsedIsSubagent = false
            default: return nil
            }
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("k=") {
            let key = String(fields[index].dropFirst(2))
            guard let uuid = UUID(uuidString: key) else { return nil }
            parsedCorrelationKey = uuid.uuidString.lowercased()
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("g=") {
            guard let guardValue = ControlSidebarAgentMutationGuard(
                socketEnvelope: String(fields[index].dropFirst(2))
            ) else { return nil }
            parsedGuard = guardValue
            index += 1
        }
        guard index == fields.count else { return nil }
        category = known
        pending = parsedPending
        agentKind = parsedAgentKind
        isSubagent = parsedIsSubagent
        correlationKey = parsedCorrelationKey
        agentMutationGuard = parsedGuard
    }

    /// Mirror of the CLI's agent-kind slug grammar: 1-64 ASCII characters
    /// from `[a-z0-9._-]`.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "." || character == "_" || character == "-")
        }
    }

    static func isValidCorrelationKey(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
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
