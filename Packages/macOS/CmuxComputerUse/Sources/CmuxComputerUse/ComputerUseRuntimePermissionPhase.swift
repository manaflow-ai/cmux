/// The host-authoritative permission phase for the standalone Computer Use helper.
public enum ComputerUseRuntimePermissionPhase: Equatable, Sendable {
    /// Computer Use is disabled; the associated value preserves verified setup.
    case disabled(onboardingComplete: Bool)
    /// Computer Use is enabled but explicit setup has not been completed.
    case onboardingRequired
    /// The setup window is currently being shown or completed.
    case onboarding
    /// Both helper profiles have an explicit, current setup record.
    case ready

    /// State transitions owned by the onboarding store.
    public enum Event: Equatable, Sendable {
        /// Applies the user's enabled preference.
        case setEnabled(Bool)
        /// Records that the setup window was claimed for presentation.
        case onboardingPresented
        /// Records a successful capture verification.
        case onboardingCompleted
        /// Invalidates evidence for a replaced helper.
        case helperReplaced
    }

    /// Whether this phase carries a completed setup record.
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

    /// Applies one state transition without performing I/O.
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
