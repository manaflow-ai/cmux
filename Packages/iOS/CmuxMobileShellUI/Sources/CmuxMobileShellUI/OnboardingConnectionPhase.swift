#if os(iOS)
/// Presentation state for the final onboarding scene.
///
/// Same-account Iroh discovery always gets the first attempt. QR pairing is
/// revealed only after that attempt finishes without a live Mac.
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
