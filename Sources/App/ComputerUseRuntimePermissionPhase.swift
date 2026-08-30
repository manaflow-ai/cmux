import Foundation

/// The host-authoritative permission phase for the standalone Computer Use helper.
enum ComputerUseRuntimePermissionPhase: Equatable, Sendable {
    case disabled(onboardingComplete: Bool)
    case onboardingRequired
    case onboarding
    case ready

    enum Event: Equatable, Sendable {
        case setEnabled(Bool)
        case onboardingPresented
        case onboardingCompleted
        case helperReplaced
    }

    var isReady: Bool {
        switch self {
        case .ready, .disabled(onboardingComplete: true):
            true
        case .disabled(onboardingComplete: false),
             .onboardingRequired,
             .onboarding:
            false
        }
    }

    func applying(_ event: Event) -> Self {
        switch event {
        case .setEnabled(false):
            return .disabled(onboardingComplete: isReady)
        case .setEnabled(true):
            switch self {
            case .disabled(onboardingComplete: true), .ready:
                return .ready
            case .disabled(onboardingComplete: false),
                 .onboardingRequired:
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
                return .disabled(onboardingComplete: true)
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
