/// Relative authority of lifecycle evidence for one status key.
nonisolated enum AgentLifecycleConfidence: Int, Comparable, Sendable {
    case unboundHook
    case liveProcess
    case feedAttention

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
