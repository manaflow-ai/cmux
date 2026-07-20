#if os(iOS)
enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case agents
    case reserved
    case connect

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .agents: "agents"
        case .reserved: "reserved"
        case .connect: "connect"
        }
    }
}
#endif
