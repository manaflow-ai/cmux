/// How strongly cmux can verify that a registered agent runtime still exists.
enum AgentStatusRuntimeLiveness: Equatable, Sendable {
    case absent
    case confirmed
    case unverifiable
}
