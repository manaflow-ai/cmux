public import AppKit
public import CmuxNextDesign

// Thunderdome r2 B, "squared" (`SquaredTabCorner`, Debug Settings `chrome.squaredTab`): the top row is the
// top bar of the whole window. The sidebar's + takes the tabs' center line, the sidebar's edge line starts
// under the row (flat), and under the framed looks the sidebar's list starts level with the content card.
extension SidebarContainerView {
    /// Lays the sidebar's top row out for the squared tab look; off keeps today's. `cardTop` is the main
    /// pane card's top inset from the window's top, `cardMaxY` its top in the superview's coordinates,
    /// `page` whether a page fills the window (no top row then).
    public func applyTopRow(cardTop: CGFloat, cardMaxY: CGFloat, page: Bool) {
        let look = SquaredTabCorner.current
        let chrome = PaneChromeMetrics.current
        let minimal = DesignSettings.shared.titlebar == .minimal
        let topRow = minimal && !page && DesignSettings.shared.tabBarPosition != .bottom
        let scale = window?.backingScaleFactor ?? 2
        // The header's height as the window's tokens set it, or under the framed looks the content card's top.
        let header = topRow && look.drawsFrame ? cardTop + Metrics.stripTopOutset + Metrics.tabStripHeight
            : minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        if sidebarView.titlebarHeightOverride != header { sidebarView.titlebarHeightOverride = header }
        guard look != .off, topRow else {
            sidebarView.tabRowCenterFromTop = nil
            updateResizeLine(cardMaxY: cardMaxY)
            return
        }
        // The top-row pills: the card's top, then the pane padding and the pill's inset in the strip.
        let pillTop = cardTop + chrome.tabGap(scale: scale)
        sidebarView.tabRowCenterFromTop = pillTop + chrome.tabHeight / 2
        updateResizeLine(cardMaxY: cardMaxY, topRowHeight: look == .flat ? pillTop + chrome.tabHeight : 0)
    }
}
