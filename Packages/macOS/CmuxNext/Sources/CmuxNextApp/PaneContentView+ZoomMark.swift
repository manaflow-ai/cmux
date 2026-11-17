import AppKit
import CmuxNextTabs

// The pane's zoom marks: the Exit Zoom button in the tab bar's trailing controls (`PaneToolbarView.zoomButton`, with
// the lit "…" and a lit pinned zoom button), or the indicator at the content's corner while the tab bar shows no
// controls (`PaneZoomIndicatorView`), and the selected tab's zoomed state for VoiceOver. Each reads one flag, the
// strip model's `zoomsSelected`.
//
// The layout writes that flag, not the store. A zoom key changes the store in the key's turn, and the screen shows
// the zoom some frames later (a zoom's dim comes first, then the panes hear their sizes). A mark that followed the
// store showed over the layout before the zoom for those frames, and went before an unzoom showed.
//
// One case stays with the store: a page that has the whole window (its fullscreen) shows its pane alone, as a zoom
// does, whatever the store's zoom is, so the layout does not change when that zoom does. While the pane presents its
// page the layout leaves the flag alone and the pane's snapshot of the store writes it (`PaneController.apply`).
extension PaneContentView {
    /// `PaneContentChrome`: the layout that the pane's screen shows has this pane zoomed, or has it not. The layout
    /// calls this in the pass that shows a layout change (`ScreenContentView.updateChrome`). The trailing controls
    /// take the flag in this call, not in their observation task, which runs a turn later.
    func setPaneShownZoomed(_ zoomed: Bool) {
        let model = stripView.model
        guard model.zoomsSelected != zoomed else { return }
        model.zoomsSelected = zoomed
        needsLayout = true // the corner indicator (`layoutAgentTag`) and the trailing controls' width
        toolbar?.refresh()
    }
}
