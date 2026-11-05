import AppKit
import CmuxNextDesign

// `sidebar.topLeftCluster = tabLead` (SidebarView+TopLeftCluster): the + leaves the sidebar header for the first tab
// strip's leading slot, so the corner reads as one row (sidebar, +, tabs) instead of a lone glyph above the list
// and a tab beside it. The button lives in the window's top row (this container's superview), right inside the
// main pane card's leading edge (this container's content-side edge plus the main pane gutter), on the traffic
// lights' line, and is the window's leading slot (`WindowControlsAvoiders.leadingSlot`): the strip under it starts
// its tabs after it, as it starts them after the traffic lights. It moves with the card as the sidebar resizes or
// slides, and hides on a right sidebar or while the sidebar is hidden.
extension SidebarContainerView {
    func placeTabLeadNewWorkspace() {
        let button = sidebarView.tabLeadButton
        guard let window, let host = superview else {
            button.isHidden = true
            return
        }
        let shows = sidebarView.showsTabLeadNewWorkspace && side == .left && !model.isHidden && !isHidden
        if shows, button.superview !== host { host.addSubview(button, positioned: .above, relativeTo: nil) }
        let before = button.isHidden || button.superview !== host ? nil : button.frame
        button.isHidden = !shows
        let avoiders = (window as? any WindowControlsAvoidanceHosting)?.windowControlsAvoiders
        var after: CGRect?
        if shows {
            avoiders?.leadingSlot = button
            let side = TitlebarBandButton.side
            let fallback = host.isFlipped ? Metrics.titlebarHeight / 2 : host.bounds.maxY - Metrics.titlebarHeight / 2
            let midY = WindowTitlebar.trafficLightsFrame(in: window).map { host.convert($0, from: nil).midY } ?? fallback
            let placed = WindowTitlebar.alignedFrame(CGRect(x: frame.maxX + Metrics.mainPaneGutter + Metrics.space1, y: midY - side / 2,
                                                            width: side, height: side), scale: window.backingScaleFactor)
            button.frame = placed
            after = placed
        } else if avoiders?.leadingSlot === button {
            avoiders?.leadingSlot = nil
        }
        if before != after { WindowControlsAvoiders.refresh(in: window) }
    }
}
