/// One inline decision sent to the Mac that owns a Feed item.
public enum MobileAgentFeedAction: Equatable, Sendable {
    case permission(mode: String)
    case exitPlan(mode: String, feedback: String?)
    case question(selections: [String])
}
