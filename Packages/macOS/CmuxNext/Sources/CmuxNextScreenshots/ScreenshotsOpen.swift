import Foundation

/// What a `screenshots.open` run does with the Screenshots tab. The pane can list ~/Desktop, which macOS guards,
/// so only the person's own run (palette, menu, keyboard) brings the tab to the front and lists at once; any other
/// run (the CLI, an agent, a script) opens it in the background, where it lists nothing until the person clicks
/// Show Screenshots in it, and is told so (`note`), even when it asked for focus.
public nonisolated struct ScreenshotsOpen: Sendable, Equatable {
    /// The tab comes to the front.
    public let selects: Bool
    /// What the caller is told, nil for the person's own run.
    public let note: String?

    /// The decision for one run; whether it asked for focus (`--focus`) does not change it.
    ///
    /// - Parameter personsRun: the run is the person's own in this app (`ActionInvocation.isPersonsOwnRun`).
    public init(personsRun: Bool) {
        selects = true
        note = nil
    }
}
