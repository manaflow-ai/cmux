/// Category an agent hook attaches to a notification so the app can gate delivery by user config.
///
/// Mirrors the CLI's `ClaudeNotifyCategory`; serialized into the
/// `notify_target_async` payload's optional `c=<category>;p=<0|1>` meta.
public enum AgentNotifyCategory: String, Sendable, Equatable {
    /// The agent finished a turn.
    case turnComplete = "turn-complete"
    /// The agent is blocked waiting for the user's permission.
    case needsPermission = "needs-permission"
    /// The agent has been idle and appears to be waiting for input.
    case idleReminder = "idle-reminder"
    /// Legacy or uncategorized notifications that do not ride the wire as meta.
    case other

    /// Returns whether an agent notification in this category should be delivered.
    ///
    /// This is the pure decision table behind app-side notification settings;
    /// callers provide the already-read settings so this package code stays free
    /// of `UserDefaults`.
    ///
    /// - Parameters:
    ///   - pending: Whether background work or a scheduled wakeup is still pending.
    ///   - permissionEnabled: Whether permission-prompt notifications are enabled.
    ///   - turnMode: The user's turn-complete notification mode.
    ///   - idleEnabled: Whether idle-reminder notifications are enabled.
    /// - Returns: `true` when the notification should be delivered.
    public func shouldDeliver(
        pending: Bool,
        permissionEnabled: Bool,
        turnMode: AgentTurnCompleteMode,
        idleEnabled: Bool
    ) -> Bool {
        switch self {
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
}
