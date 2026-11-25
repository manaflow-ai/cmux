import CmuxNextBridge
import CmuxNextSettings

extension PaneController {
    /// Full Width Tab on this pane: tab `id` is selected first (classic focused it), so turning
    /// the mode on shows the tab the action was run on.
    func toggleFullWidthTab(showing id: StripTabID) {
        if stripModel.selectedID != id, stripModel.tab(id) != nil { select(id) }
        services.paneFullWidthTabs.toggle(paneKey)
        apply(snapshot())
    }
}
