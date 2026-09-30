public import AppKit
public import CmuxNextDesign

// The toolbar, separator and progress line are the pane's header: the pane
// border and rounded corners trace only the page area below them, which
// holds the page, docked DevTools and the page's overlays.
extension BrowserChromeView: PaneContentChrome {
    public var paneHeaderHeight: CGFloat { pageAreaTop }

    public func setPaneContentCornerRadius(_ radius: CGFloat) {
        guard let layer = contentContainer.layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
        // A Chromium page re-reads this rounded ancestor when the layout
        // reports a pane shape change (`paneShapesDidChange`).
    }

    /// Points from the top edge to the page area, from the laid-out frame.
    var pageAreaTop: CGFloat {
        isFlipped ? contentContainer.frame.minY : bounds.maxY - contentContainer.frame.maxY
    }
}
