public import AppKit
import CmuxNextDesign

// A strip under the window's traffic lights (minimal titlebar, sidebar
// hidden, the top-left pane) starts its tabs after them. Only strips whose
// frame overlaps the traffic lights get the inset, so it follows sidebar
// show and hide, splits, column scrolling and fullscreen.
extension TabStripView {
    /// Re-checks the traffic lights after the strip moved in its window
    /// without a resize (the App calls it when the pane's window frame
    /// changes); relays out only when the inset changes.
    public func updateWindowControlsAvoidance() {
        guard computeWindowControlsInset() != windowControlsInset else { return }
        needsLayout = true
    }

    /// Leading points to keep clear so the first tab starts a little after
    /// the traffic lights; 0 when the strip is not under them.
    func computeWindowControlsInset() -> CGFloat {
        guard let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) else { return 0 }
        let strip = convert(bounds, to: nil)
        guard strip.minY < lights.maxY, strip.maxY > lights.minY, strip.minX < lights.maxX, strip.maxX > lights.minX else { return 0 }
        let clear = lights.maxX + Metrics.space3 - strip.minX - metrics.stripHorizontalPadding
        return max(0, (clear * 2).rounded(.up) / 2)
    }

    /// Whether empty strip space acts as a titlebar right now.
    var actsAsTitlebar: Bool {
        dragsWindowFromEmptySpace && WindowTitlebar.isInTopRow(self)
    }
}
