import AppKit

/// Host glass for any page (RFD 0207): the boxes a page reports with `cmux.app.glass` get the App's
/// own glass under the page (``PageHostGlassLayer``), the agent pane's `pane.glass` for every page.
/// The layer is made on the first report that marks a surface, so a page that marks none (every page
/// today) has no view more and looks the same.
extension PageWebView {
    /// Draws the page's last report: makes the layer on the first surface, places each box at the
    /// zoom the page measured it at, and removes the layer once the page marks nothing.
    func applyHostGlass(_ surfaces: [PageHostGlassSurface]) {
        guard !surfaces.isEmpty else {
            hostGlassLayer?.removeFromSuperview()
            hostGlassLayer = nil
            return
        }
        let layer: PageHostGlassLayer
        if let known = hostGlassLayer {
            layer = known
        } else {
            layer = PageHostGlassLayer(frame: bounds)
            layer.autoresizingMask = [.width, .height]
            // Under the page's content: its see-through pixels show the glass, its content draws on top
            // (a Chromium page is a child window above this view, so the glass shows through it the same).
            addSubview(layer, positioned: .below, relativeTo: webView)
            hostGlassLayer = layer
        }
        if layer.frame != bounds { layer.frame = bounds }
        layer.apply(surfaces, paneZoom: CGFloat(pageZoom))
    }
}
