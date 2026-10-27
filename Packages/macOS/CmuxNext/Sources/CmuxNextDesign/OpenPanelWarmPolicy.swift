public import CmuxNextCompat

/// When the app's file picker (``MadeAheadOpenPanel``) is made, and how long it is kept.
///
/// Each `NSOpenPanel` starts the system's open and save panel service, a separate process that stays while the
/// panel lives. Chrome makes its file dialog for each request and none at startup
/// (ui/shell_dialogs/select_file_dialog_mac.mm), so a session that never picks a file runs no picker process.
@MainActor
public enum OpenPanelWarmPolicy {
    /// The panel is made at a pause after launch, or when a view that offers the picker reaches a window, and kept
    /// for the life of the process: even the first click pays only the sheet.
    case ahead
    /// No panel is made until a click asks for one: the launch's and the views' warm-ups make none. The click's
    /// panel is kept for later clicks and is an overlay page on `terms` (``OverlayPageRelease``): the App's one overlay
    /// page planner releases it once it went unused for the terms' `releaseAfter` (as the Memory Saver mode scales
    /// it), or at warning or critical pressure, at a look where no sheet or window shows it, so the panel service can
    /// exit. After a release, warm-ups again wait for a click.
    case afterFirstUse(OverlayPageReleaseTerms)

    /// Whether a warm-up may make a panel now, given whether a click asked for one since the last release.
    func allowsWarmUp(usedSinceRelease: Bool) -> Bool {
        switch self {
        case .ahead: true
        case .afterFirstUse: usedSinceRelease
        }
    }
}
