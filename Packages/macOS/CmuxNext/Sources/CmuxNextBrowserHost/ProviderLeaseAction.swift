/// A person's action on a tab's automation lease (plans/cmux-next/automation-lease.md,
/// "Actions"): the `op` of a `lease.user` frame. The host owns the state machine;
/// `applies(toWireState:)` only hides a button the host would refuse.
public nonisolated enum ProviderLeaseAction: String, CaseIterable, Hashable, Sendable {
    /// driving or paused -> user_driving: the agent's input stops until Hand back.
    case takeOver = "take_over"
    /// paused or user_driving -> driving: the agent observes again before acting.
    case handBack = "hand_back"
    /// Ends the lease and stops its principal (always available).
    case stop

    /// Whether the action applies to a lease in wire state `state`
    /// (`driving`, `paused`, `user_driving`; nil or unknown reads as driving).
    public func applies(toWireState state: String?) -> Bool {
        let state = state ?? "driving"
        switch self {
        case .stop: return true
        case .takeOver: return state == "driving" || state == "paused"
        case .handBack: return state == "paused" || state == "user_driving"
        }
    }

    /// The actions a lease in `state` offers, in badge order.
    public static func offered(forWireState state: String?) -> [ProviderLeaseAction] {
        [.takeOver, .handBack, .stop].filter { $0.applies(toWireState: state) }
    }
}
