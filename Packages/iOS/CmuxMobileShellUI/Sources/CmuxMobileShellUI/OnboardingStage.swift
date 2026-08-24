#if os(iOS)
enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case welcome
    case connect
    case push

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .welcome: "welcome"
        case .connect: "connect"
        case .push: "push"
        }
    }
}
#endif
