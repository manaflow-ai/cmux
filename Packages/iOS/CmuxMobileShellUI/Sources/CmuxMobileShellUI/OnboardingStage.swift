#if os(iOS)
enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case agents
    case handoff
    case connect

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .agents: "agents"
        case .handoff: "handoff"
        case .connect: "connect"
        }
    }
}
#endif
