/// Outcome returned by host-owned custom-sidebar onboarding actions.
public enum CustomSidebarOnboardingResult: Equatable, Sendable {
    /// A sidebar file was created successfully.
    case created(name: String)

    /// A bundled starter or example could not be loaded or validated.
    case templateUnavailable

    /// The host could not write the sidebar file.
    case writeFailed
}
