import AppKit
import CmuxNextDesign

/// The times a tab strip does not follow its model at once, and the one sync it owes for them.
///
/// - Out of sight (a parked workspace's strip, a hidden screen bar): the strip lays nothing out and animates nothing,
///   and syncs once to the final state when it shows.
/// - Its pane leaves: a close took the strip's last tabs out of its model, and the pane still shows until the layout's
///   next frame hides it. The strip keeps the tabs it shows, so the tab and its pane go in one frame. Without this the
///   pane showed for a frame with an empty tab bar. When the pane shows again (a refused close) the strip syncs once.
@MainActor
final class TabStripSyncHold {
    /// The model changed while the strip was out of sight.
    private var changedOutOfSight = false
    /// The strip kept the tabs of a pane that leaves, while its model had none.
    private var keptTabsOfLeavingPane = false

    /// Whether `strip` leaves its model's change for later, now. `atRest`: whether no gesture, drop or order override
    /// is in flight on the strip; read only for a strip that shows tabs while its model has none.
    ///
    /// A tab that left by a move to another pane shows there (`TabStripModel.departures`): a strip that shows such a
    /// tab keeps nothing, and neither does a strip in a gesture.
    func holds(_ strip: TabStripView, atRest: @autoclosure () -> Bool) -> Bool {
        if strip.window != nil, !strip.isShownInWindow {
            changedOutOfSight = true
            return true
        }
        let model = strip.model
        guard model.tabs.isEmpty, !strip.cells.isEmpty, atRest(), model.departures.isDisjoint(with: strip.cells.keys),
              strip.isInALeavingPane else { return false }
        keptTabsOfLeavingPane = true
        return true
    }

    /// Whether the strip owes a sync now that it shows. The hold ends.
    func takeOwedSync() -> Bool {
        let owed = changedOutOfSight || keptTabsOfLeavingPane
        changedOutOfSight = false
        keptTabsOfLeavingPane = false
        return owed
    }
}
