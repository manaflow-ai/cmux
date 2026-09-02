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

/// Parsed `c=<category>;p=<0|1>[;a=<agent-kind>][;n=<0|1>][;s=<alert>][;k=<uuid>][;k=<status>;t=<seconds>]` meta segment.
/// Returns `nil` unless BOTH a KNOWN category literal and a valid `p=0|1`
/// pending flag are present, so the reserved suffix grammar stays exactly the
/// three known categories — any other `c=...` tail stays part of the legacy
/// notification body. (`.other` never rides the wire: senders omit the meta
/// entirely for ungated alerts.)
///
/// The optional trailing fields carry agent-event context for the user's
/// notification-policy hooks: `a=` is the case-preserving registry identifier
/// (`claude`, `codex`, `MyAgent`, …) and `n=` marks a nested subagent session.
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
    /// Status-watermark key carried by ordered cmux hook notifications.
    let agentStatusKey: String?
    /// Event timestamp paired with ``agentStatusKey`` for ordering.
    let agentEventTime: TimeInterval?

    init?(meta: String) {
        // Accept only the canonical serialization emitted by the CLI. The
        // sound field precedes notification identity, which precedes the
        // optional ordered status pair; reordered or unknown fields remain in
        // the legacy notification body.
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard (2...8).contains(fields.count),
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p="),
              let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))) else {
            return nil
        }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        var parsedSoundContext: NotificationSoundOverrideContext?
        var index = 2
        var parsedAgentKind: String?
        var parsedIsSubagent: Bool?
        var parsedCorrelationKey: String?
        var parsedStatusKey: String?
        var parsedEventTime: TimeInterval?
        if index < fields.count, fields[index].hasPrefix("a=") {
            let value = String(fields[index].dropFirst(2))
            guard Self.isValidAgentKindTag(value) else { return nil }
            parsedAgentKind = value
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
            guard let parsedAgentKind,
                  let alertType = NotificationSoundAlertType(
                      rawValue: String(fields[index].dropFirst(2))
                  ),
                  let context = NotificationSoundOverrideContext(
                      agentID: parsedAgentKind,
                      alertType: alertType
                  ),
                  known.soundAlertType == alertType
                    || (known == .other && alertType == .errorStalled)
            else { return nil }
            parsedSoundContext = context
            index += 1
        }
        while index < fields.count {
            guard fields[index].hasPrefix("k=") else { return nil }
            let key = String(fields[index].dropFirst(2))
            if index + 1 < fields.count, fields[index + 1].hasPrefix("t=") {
                guard parsedStatusKey == nil,
                      !key.isEmpty,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
                      let eventTime = TimeInterval(fields[index + 1].dropFirst(2)),
                      Self.isPlausibleAgentEventTime(eventTime) else { return nil }
                parsedStatusKey = key
                parsedEventTime = eventTime
                index += 2
            } else {
                guard parsedCorrelationKey == nil,
                      parsedStatusKey == nil,
                      let uuid = UUID(uuidString: key) else { return nil }
                parsedCorrelationKey = uuid.uuidString.lowercased()
                index += 1
            }
        }
        guard index == fields.count else { return nil }
        guard (parsedStatusKey == nil) == (parsedEventTime == nil) else { return nil }
        guard known != .other || parsedSoundContext != nil || parsedStatusKey != nil else { return nil }
        self.category = known
        self.agentKind = parsedAgentKind
        self.isSubagent = parsedIsSubagent
        self.soundContext = parsedSoundContext
        self.correlationKey = parsedCorrelationKey
        self.agentStatusKey = parsedStatusKey
        self.agentEventTime = parsedEventTime
    }

    /// Accepts current Unix timestamps while rejecting malformed or far-future values.
    private static func isPlausibleAgentEventTime(_ value: TimeInterval) -> Bool {
        value.isFinite
            && value >= 946_684_800
            && value <= Date.now.timeIntervalSince1970 + 5 * 60
    }

    /// Mirror of the CLI's `AgentHookNotifyCategory.isValidAgentKindTag` slug
    /// grammar: 1-64 ASCII characters of `[A-Za-z0-9._-]`, excluding `.` and
    /// `..`. Both sides must agree exactly or the meta folds back into the body.
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
