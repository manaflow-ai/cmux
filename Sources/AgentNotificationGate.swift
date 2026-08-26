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

/// Parsed `c=<category>;p=<0|1>[;a=<agent-kind>][;n=<0|1>][;s=<alert>][;k=<uuid>]` meta segment.
/// Returns `nil` unless BOTH a KNOWN category literal and a valid `p=0|1`
/// pending flag are present, so the reserved suffix grammar stays exactly the
/// three known categories — any other `c=...` tail stays part of the legacy
/// notification body. (`.other` never rides the wire: senders omit the meta
/// entirely for ungated alerts.)
///
/// The optional trailing fields carry agent-event context for the user's
/// notification-policy hooks: `a=` is the stable lowercase agent slug
/// (`claude`, `codex`, `grok`, …) and `n=` marks a nested subagent session.
/// Pre-extension senders emit only `c=;p=` and parse exactly as before.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentKind: String?
    let isSubagent: Bool?
    let soundContext: NotificationSoundOverrideContext?
    /// Opaque identity used by a producer that needs to clear exactly one
    /// notification without touching newer entries on the same surface.
    let correlationKey: String?

    init?(meta: String) {
        // Accept ONLY the canonical serialization the CLI emits (`c=` then
        // `p=`, optionally followed by `a=`, `n=`, `s=`, then `k=`, this order,
        // no duplicates or extras). Anything else — reordered, duplicated, or
        // unknown trailing fields — is not metadata and stays part of the
        // legacy notification body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard (2...6).contains(fields.count),
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))) else {
            return nil
        }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        var agentKind: String? = nil
        var isSubagent: Bool? = nil
        var soundContext: NotificationSoundOverrideContext? = nil
        var correlationKey: String? = nil
        var index = 2
        if index < fields.count, fields[index].hasPrefix("a=") {
            let kind = String(fields[index].dropFirst(2))
            guard Self.isValidAgentKindTag(kind) else { return nil }
            agentKind = kind
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("n=") {
            switch fields[index].dropFirst(2) {
            case "1": isSubagent = true
            case "0": isSubagent = false
            default: return nil
            }
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("s=") {
            guard let agentKind,
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
            soundContext = context
            index += 1
        }
        if index < fields.count, fields[index].hasPrefix("k=") {
            let key = String(fields[index].dropFirst(2))
            guard let uuid = UUID(uuidString: key) else { return nil }
            correlationKey = uuid.uuidString.lowercased()
            index += 1
        }
        guard index == fields.count else { return nil }
        guard known != .other || soundContext != nil else { return nil }
        self.category = known
        self.agentKind = agentKind
        self.isSubagent = isSubagent
        self.soundContext = soundContext
        self.correlationKey = correlationKey
    }

    /// Mirror of the CLI's `AgentHookNotifyCategory.isValidAgentKindTag` slug
    /// grammar: 1-64 characters of `[a-z0-9._-]`. Both sides must agree
    /// exactly or the meta folds back into the notification body.
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
