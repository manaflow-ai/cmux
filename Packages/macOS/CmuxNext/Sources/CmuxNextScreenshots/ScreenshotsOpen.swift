import CCmuxScreenshots
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
        let said = cmux_screenshots_open(selects, existing, listing)
        guard said.opened != 0 else { return nil }
        return (said.opened == 2 ? "existing" : "background", said.listing, Self.words(said.note))
    }

    /// The decision for one run; whether it asked for focus (`--focus`) does not change it.
    ///
    /// - Parameter personsRun: the run is the person's own in this app (`ActionInvocation.isPersonsOwnRun`).
    public init(personsRun: Bool) {
        selects = personsRun
        note = Self.words(cmux_screenshots_open(personsRun, false, false).note)
    }

    /// The app's words for the C ABI's note (0 none, 1 opened in the background, 2 waiting for a click).
    private static func words(_ note: UInt32) -> String? {
        switch note {
        case 1: ScreenshotsStrings.openedInBackground
        case 2: ScreenshotsStrings.existingNeedsClick
        default: nil
        }
    }
}
