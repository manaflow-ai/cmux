#if os(iOS)
enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case agents
    case simulator
    case notifications
    case connect

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .agents: "agents"
        case .simulator: "simulator"
        case .notifications: "notifications"
        case .connect: "connect"
        }
    }
}
#endif
