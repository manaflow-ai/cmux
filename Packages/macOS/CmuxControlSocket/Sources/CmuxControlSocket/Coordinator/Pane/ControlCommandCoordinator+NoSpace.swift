internal import Foundation

/// Shared rendering for a split refused by the minimum pane size (used by
/// `surface.split` and `pane.create`).
extension ControlCommandCoordinator {
    /// `no_space` for a split that would leave a pane below the minimum pane
    /// size even after borrowing room from its row or column. Nothing was
    /// created, so automation can close a pane, enlarge the window, or split
    /// a larger pane and retry.
    var noSpaceForNewPaneResult: ControlCallResult {
        .err(code: "no_space", message: "No space for new pane", data: nil)
    }
}
