import CmuxControlSocket
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
}

/// User policy for the "Claude finished a turn" notification.
enum AgentTurnCompleteMode: String {
    case whenIdle
    case always
    case never
}

/// Parsed notification metadata for delivery policy, agent context, and
/// apply-time ownership. Canonical fields are
/// `c=<category>;p=<0|1>[;a=<agent-kind>][;n=<0|1>][;s=<alert>][;k=<uuid>][;g=<guard>]`.
/// Returns `nil` unless BOTH a KNOWN category literal and a valid `p=0|1`
/// pending flag are present, so the reserved suffix grammar stays exactly the
/// three known categories — any other `c=...` tail stays part of the legacy
/// notification body. (`.other` never rides the wire: senders omit the meta
/// entirely for ungated alerts.)
///
/// The optional trailing fields carry agent-event context for the user's
/// notification-policy hooks: `a=` is the case-preserving registry identifier
/// (`claude`, `codex`, `MyAgent`, …), `n=` marks a nested subagent session,
/// `s=` carries the sound override, `k=` identifies one notification, and
/// `g=` carries the apply-time occupant guard. A guard-only `g=` form is
/// accepted for uncategorized notifications.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentKind: String?
    let isSubagent: Bool?
    let soundContext: NotificationSoundOverrideContext?
    /// Opaque identity used by a producer that needs to clear exactly one
    /// notification without touching newer entries on the same surface.
    let correlationKey: String?
    let agentMutationGuard: ControlSidebarAgentMutationGuard?

    init?(meta: String) {
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        if fields.count == 1, fields[0].hasPrefix("g=") {
            guard let guardValue = ControlSidebarAgentMutationGuard(
                socketEnvelope: String(fields[0].dropFirst(2))
            ) else { return nil }
            category = .other
            pending = false
            agentKind = nil
            isSubagent = nil
            soundContext = nil
            correlationKey = nil
            agentMutationGuard = guardValue
            return
        }

        // Accept only the canonical field order so user-authored notification
        // text containing a lookalike suffix remains ordinary body text.
        guard (2...7).contains(fields.count),
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))) else {
            return nil
        }
        let parsedPending: Bool
        switch fields[1].dropFirst(2) {
        case "1": parsedPending = true
        case "0": parsedPending = false
        default: return nil
        }
        var parsedAgentKind: String?
        var parsedIsSubagent: Bool?
        var parsedSoundContext: NotificationSoundOverrideContext?
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
        if index < fields.count, fields[index].hasPrefix("s=") {
            guard let agentKind = parsedAgentKind,
                  let alertType = NotificationSoundAlertType(
                      rawValue: String(fields[index].dropFirst(2))
                  ),
                  let context = NotificationSoundOverrideContext(
                      agentID: agentKind,
                      alertType: alertType
                  ),
                  known.soundAlertType == alertType
                    || (known == .other && alertType == .errorStalled)
            else { return nil }
            parsedSoundContext = context
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
        guard known != .other || parsedSoundContext != nil || parsedGuard != nil else {
            return nil
        }
        category = known
        pending = parsedPending
        agentKind = parsedAgentKind
        isSubagent = parsedIsSubagent
        soundContext = parsedSoundContext
        correlationKey = parsedCorrelationKey
        agentMutationGuard = parsedGuard
    }

    /// Mirror of the CLI's agent-kind slug grammar: 1-64 ASCII characters
    /// from `[a-z0-9._-]`.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        NotificationSoundOverrideContext.isValidAgentID(value)
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
