/// Outcome returned by host-owned custom-sidebar onboarding actions.
public enum CustomSidebarOnboardingResult: Equatable, Sendable {
    /// A sidebar file was created successfully.
    case created(name: String)

    /// The requested file name cannot be used safely.
    case invalidName

    /// A discovered sidebar already uses the requested name.
    case alreadyExists

    /// A bundled starter or example could not be loaded or validated.
    case templateUnavailable

    /// The host could not write the sidebar file.
    case writeFailed
}
