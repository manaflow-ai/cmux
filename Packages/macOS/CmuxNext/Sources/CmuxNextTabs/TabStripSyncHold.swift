import AppKit
import CmuxNextDesign

/// The times a tab strip does not follow its model at once, and the one sync it owes for them.
///
/// - Out of sight (a parked workspace's strip, a hidden screen bar): the strip lays nothing out and animates nothing,
///   and syncs once to the final state when it shows, if it does not show that state already.
/// - Its pane leaves: a close took the strip's last tabs out of its model, and the pane still shows until the layout's
///   next frame hides it. The strip keeps the tabs it shows, so the tab and its pane go in one frame. Without this the
///   pane showed for a frame with an empty tab bar. When the pane shows again (a refused close) the strip syncs once.
@MainActor
final class TabStripSyncHold {
    /// A sync was asked while the strip was out of sight: its model changed, or not (``syncOwed(_:)`` compares).
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
              Self.paneIsLeaving(above: strip) else { return false }
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

    /// Runs the sync that `strip` owes now that it shows, with no motion: nobody saw the change. The hold ends.
    ///
    /// A strip that shows its model already does no work, as a shown strip's echo does none (a zoom asks the strip of
    /// each pane that it covers, with no change in its model): the model is the one that the strip last synced, nothing
    /// is in flight (a tab that slid out as the strip hid goes now), and the tabs are laid out at the strip's width (a
    /// hide ends closing mode with no layout). A width that changed out of sight needs no sync: the strip's own layout
    /// pass follows it (`TabStripView.layout()`).
    func syncOwed(_ strip: TabStripView) {
        guard takeOwedSync() else { return }
        strip.layOutPaneIfOneTabChanged()
        if strip.hasSynced, strip.lastSyncedInput == TabStripView.ModelSnapshot(strip.model), strip.isAtRest(),
           strip.result.availableWidth == strip.viewportWidth { return }
        strip.sync(fromModel: true, animating: false)
    }

    /// Whether the first pane host above `strip` says that its pane left the layout (`PaneLeaving`); false with no
    /// such host. The walk over the superviews stops at that host.
    private static func paneIsLeaving(above strip: TabStripView) -> Bool {
        var view = strip.superview
        while let current = view {
            if let host = current as? PaneLeaving { return host.isLeaving }
            view = current.superview
        }
        return false
    }
}
