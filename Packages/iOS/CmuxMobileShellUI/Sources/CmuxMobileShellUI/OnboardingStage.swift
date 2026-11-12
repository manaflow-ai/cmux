#if os(iOS)
enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case agents
    case notifications
    case push
    case pairing
    case connect

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .agents: "agents"
        case .notifications: "notifications"
        case .push: "push"
        case .pairing: "pairing"
        case .connect: "connect"
        }
    }
}
#endif
