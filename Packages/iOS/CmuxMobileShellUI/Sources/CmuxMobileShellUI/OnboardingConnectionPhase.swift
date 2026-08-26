#if os(iOS)
/// Presentation state for the final onboarding scene, which connects the
/// phone to a Mac by scanning the Tailscale pairing code.
enum OnboardingConnectionPhase: Equatable, Sendable {
    case idle
    case searching
    case fallback
    case ready

    init(
        isMacReady: Bool,
        isSearching: Bool,
        didFinishSearch: Bool
    ) {
        if isMacReady {
            self = .ready
        } else if isSearching {
            self = .searching
        } else if !didFinishSearch {
            self = .idle
        } else {
            self = .fallback
        }
    }
}
#endif
