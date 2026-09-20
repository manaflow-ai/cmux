/// The host-authoritative permission phase for the standalone Computer Use helper.
public enum ComputerUseRuntimePermissionPhase: Equatable, Sendable {
    case disabled(onboardingComplete: Bool)
    case onboardingRequired
    case onboarding
    case ready

    public enum Event: Equatable, Sendable {
        case setEnabled(Bool)
        case onboardingPresented
        case onboardingCompleted
        case helperReplaced
    }

    public var isReady: Bool {
        switch self {
        case .ready, .disabled(onboardingComplete: true):
            true
        case .disabled(onboardingComplete: false),
             .onboardingRequired,
             .onboarding:
            false
        }
    }

    public func applying(_ event: Event) -> Self {
        switch event {
        case .setEnabled(false):
            return .disabled(onboardingComplete: isReady)
        case .setEnabled(true):
            switch self {
            case .disabled(onboardingComplete: true), .ready:
                return .ready
            case .disabled(onboardingComplete: false), .onboardingRequired:
                return .onboardingRequired
            case .onboarding:
                return .onboarding
            }
        case .onboardingPresented:
            switch self {
            case .onboardingRequired:
                return .onboarding
            case .disabled, .onboarding, .ready:
                return self
            }
        case .onboardingCompleted:
            switch self {
            case .disabled:
                return self
            case .onboardingRequired, .onboarding, .ready:
                return .ready
            }
        case .helperReplaced:
            switch self {
            case .disabled:
                return .disabled(onboardingComplete: false)
            case .onboardingRequired, .onboarding, .ready:
                return .onboardingRequired
            }
        }
    }
}
