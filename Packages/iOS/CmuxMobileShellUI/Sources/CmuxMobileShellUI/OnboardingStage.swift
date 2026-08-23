#if os(iOS)
enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case agents
    case notifications
    case pushNotifications
    case connect

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .agents: "agents"
        case .notifications: "notifications"
        case .pushNotifications: "push_notifications"
        case .connect: "connect"
        }
    }
}
#endif
