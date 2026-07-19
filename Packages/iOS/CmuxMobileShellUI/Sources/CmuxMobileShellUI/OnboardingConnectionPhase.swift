#if os(iOS)
/// Presentation state for the final onboarding scene.
///
/// Same-account Iroh discovery always gets the first attempt. QR pairing is
/// revealed only after that attempt finishes without a live Mac.
enum OnboardingConnectionPhase: Equatable, Sendable {
    case searching
    case fallback
    case ready

    static func resolve(
        isMacReady: Bool,
        isSearching: Bool,
        didFinishSearch: Bool
    ) -> OnboardingConnectionPhase {
        if isMacReady {
            return .ready
        }
        if isSearching || !didFinishSearch {
            return .searching
        }
        return .fallback
    }
}
#endif
