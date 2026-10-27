public import AppKit

extension TabStripView {
    /// The layers the strip's window controls inset places (``updateWindowControlsAvoidance()``): the
    /// tabs' clip, the scrolling layer and edge-fade mask sized from it, and the + button after the last
    /// tab. A change of the window's top row (the toolbar band opening over a hidden sidebar) lays the
    /// strip out once and springs these together from where they showed on the render server, so the
    /// tabs and the fade fill the clip that shows (chrome-parity R2: a sublayer that does not scale with
    /// its host gets its own spring on the host's token).
    public var windowControlsLayers: [CALayer] {
        let layers: [CALayer?] = [tabsClip.layer, scrollingLayer, edgeFade.mask, newTabButton.layer]
        return layers.compactMap(\.self)
    }
}
