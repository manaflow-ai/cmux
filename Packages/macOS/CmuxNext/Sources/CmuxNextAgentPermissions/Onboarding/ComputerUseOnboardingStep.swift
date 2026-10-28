/// One step of computer use onboarding: each answers one question the
/// person has, with one action (plans/cmux-next/agent-permissions-DESIGN.md
/// section 6).
public nonisolated enum ComputerUseOnboardingStep: String, Sendable, Equatable, CaseIterable {
    /// This build has no signed Computer Use helper: nothing can be granted.
    case unavailable
    /// What computer use does and that nothing runs until the person allows it.
    case intro
    /// Accessibility: lets the agent click and type in other apps.
    case accessibility
    /// Screen Recording: lets the agent see the window it works in.
    case screenRecording = "screen_recording"
    /// A test click in a sandbox window proves both grants work.
    case tryIt = "try_it"
    /// How to stop an agent and how to take the grants back. Done follows.
    case howToStop = "how_to_stop"

    /// The steps the progress dots count, in order.
    public static let counted: [ComputerUseOnboardingStep] = [.intro, .accessibility, .screenRecording, .tryIt, .howToStop]

    /// The grant this step asks for, nil for steps without one.
    public var grant: PermissionKind? {
        switch self {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .unavailable, .intro, .tryIt, .howToStop: nil
        }
    }
}
