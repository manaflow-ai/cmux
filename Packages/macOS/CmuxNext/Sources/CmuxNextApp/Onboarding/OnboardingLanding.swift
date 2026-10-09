/// Where the window behind onboarding goes when the first run ends.
enum OnboardingLanding: Equatable {
    /// The window stays as it is.
    case stay
    /// Select this workspace (it is on the New Tab page).
    case select(workspaceID: String)
    /// A new workspace on the New Tab page (`newTab`).
    case newWorkspace

    nonisolated static func decide(firstRun: Bool, hasOpenWindow: Bool, shown: TopPageRoute?, fresh: String?) -> OnboardingLanding {
        .stay
    }
}
