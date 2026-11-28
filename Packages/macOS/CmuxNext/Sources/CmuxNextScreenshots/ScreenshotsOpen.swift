import Foundation

/// What a `screenshots.open` run does with the Screenshots tab. The pane lists nothing until the person clicks Show
/// Screenshots in it (macOS guards ~/Desktop), and only the person's own run (palette, menu, keyboard) brings the tab
/// to the front; any other run (the CLI, an agent, a script) opens it in the background and is told so (`note`), even
/// when it asked for focus.
public nonisolated struct ScreenshotsOpen: Sendable, Equatable {
    /// The tab comes to the front.
    public let selects: Bool
    /// What the caller is told, nil for the person's own run.
    public let note: String?
    /// The run's answer to a capturing caller (`action.run` `result`), nil for the person's own run: a new tab
    /// opened in the background, or the tab already open, with whether it lists (the person clicked in it).
    ///
    /// - Parameters:
    ///   - existing: the window already had a Screenshots tab.
    ///   - listing: that tab lists its folders.
    public func result(existing: Bool, listing: Bool) -> (opened: String, listing: Bool, note: String?)? {
        guard let note else { return nil }
        guard existing else { return ("background", false, note) }
        return ("existing", listing, listing ? nil : ScreenshotsStrings.existingNeedsClick)
    }

    /// The decision for one run; whether it asked for focus (`--focus`) does not change it.
    ///
    /// - Parameter personsRun: the run is the person's own in this app (`ActionInvocation.isPersonsOwnRun`).
    public init(personsRun: Bool) {
        selects = personsRun
        note = personsRun ? nil : ScreenshotsStrings.openedInBackground
    }
}
