#if os(iOS)
enum OnboardingContext: String, Sendable {
    case firstRun = "first_run"
    case replay
    case preview
}
#endif
