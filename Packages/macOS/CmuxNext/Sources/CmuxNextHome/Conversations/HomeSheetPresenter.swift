public import AppKit
import CmuxNextDesign

/// Shows one of Home's sheets (Invite, Invite to Team, New Chief) over `window`.
///
/// The one presentation path for every Home sheet: the Home page, the docked Home and the
/// palette's runs all reach it.
@MainActor
public struct HomeSheetPresenter {
    /// A presenter; it holds no state (the sheet and its window do).
    public init() {}

    /// Shows `sheet` over `window` in the scope of `themeSource` (a room's own theme).
    ///
    /// - Parameters:
    ///   - sheet: The sheet to show; its `onFinish` runs once when it closes.
    ///   - window: The window it blocks while it shows.
    ///   - themeSource: The view whose theme scope the sheet draws in.
    public func present(_ sheet: HomeSheetController, over window: NSWindow, themeSource: NSView? = nil) {
        let panel = NSWindow(contentViewController: sheet)
        // The sheet draws in this page's scope (a room's own theme), not the app's: its labels
        // resolved before the sheet had a parent.
        if let themeSource { panel.adoptThemeScope(of: themeSource) }
        window.beginSheet(panel)
    }
}
