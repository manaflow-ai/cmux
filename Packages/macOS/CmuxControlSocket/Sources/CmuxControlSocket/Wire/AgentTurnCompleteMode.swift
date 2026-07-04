/// User policy for the "agent finished a turn" notification.
public enum AgentTurnCompleteMode: String, Sendable, Equatable {
    /// Deliver turn-complete notifications only when no background work is pending.
    case whenIdle
    /// Always deliver turn-complete notifications.
    case always
    /// Never deliver turn-complete notifications.
    case never
}
