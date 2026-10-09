/// Where the window behind onboarding goes when the first run ends (D3,
/// spec D9): Skip and Done land the same, on a New Tab page. Pure, so the
/// rules are tested without windows (`OnboardingService.land`).
enum OnboardingLanding: Equatable {
    /// The window stays as it is.
    case stay
    /// Select this workspace (the launch's fresh one, on the New Tab page).
    case select(workspaceID: String)
    /// A new workspace on the New Tab page (`newTab`).
    case newWorkspace

    /// - Parameters:
    ///   - firstRun: the window showed the first run (a single-step window,
    ///     such as Import and Sync, never moves the main window).
    ///   - hasOpenWindow: a main window is open.
    ///   - shown: the top page the active main window shows; nil when it
    ///     shows a workspace.
    ///   - fresh: the launch's fresh New Tab workspace, if it still exists.
    /// Home (or no window) is where nothing is chosen yet, so the person
    /// lands on a New Tab; a workspace or another page (Settings, App
    /// Store) is something they chose, so it stays.
    nonisolated static func decide(firstRun: Bool, hasOpenWindow: Bool, shown: TopPageRoute?, fresh: String?) -> OnboardingLanding {
        guard firstRun, !hasOpenWindow || shown == .home else { return .stay }
        return fresh.map { .select(workspaceID: $0) } ?? .newWorkspace
    }
}
