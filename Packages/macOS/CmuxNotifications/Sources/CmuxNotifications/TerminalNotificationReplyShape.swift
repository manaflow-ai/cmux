/// The inline-reply affordance declared by a terminal notification.
public enum TerminalNotificationReplyShape: String, Sendable, Equatable {
    /// The notification is open-only and has no inline reply control.
    case none

    /// The notification accepts a free-text reply.
    case text

    /// Creates a reply shape from its socket wire value.
    ///
    /// Unknown and absent values deliberately fall back to ``none``.
    ///
    /// - Parameter wire: The optional wire value.
    public init(wire: String?) {
        self = wire.flatMap(Self.init(rawValue:)) ?? .none
    }

    /// Derives the reply shape for an agent notification category wire value.
    ///
    /// - Parameter agentCategoryWire: The agent category, if supplied.
    /// - Returns: Text reply for turn-complete and idle-reminder only.
    public static func forAgentCategory(wire agentCategoryWire: String?) -> Self {
        switch agentCategoryWire {
        case "turn-complete", "idle-reminder":
            return .text
        default:
            return .none
        }
    }
}
