import AppKit
import CmuxNextDesign

// R109 `tabs.barOrder`: with the strip and a browser's toolbar on one edge
// (`tabs.barPosition`, `browser.toolbarPosition`) and the strip between the
// toolbar and the page (below a top toolbar, above a bottom one), the browser
// opens a band beside its toolbar rows (`PaneHeaderBandHosting`) and the pane
// frames the strip on it each time the browser lays out, so it moves in the
// toolbar's animation frames without changing parent
// (frames, no constraints across the two views).
// The pane stops framing before the browser leaves it on every path: this
// pane's show and detach, and the browser's own viewWillMove hooks
// (`onPaneHeaderBandRelease`, v4 review).
extension PaneContentView {
    /// The band host this pane wants now; nil keeps the strip in its frame.
    private var wantedBandHost: (any PaneHeaderBandHosting)? {
        guard hostsContent, Self.stripSitsInBand(strip: barPosition, toolbar: toolbarPosition, order: barOrder) else { return nil }
        return content as? any PaneHeaderBandHosting
    }

    /// Whether the strip goes between a browser's toolbar and its page: both on one edge, and
    /// the order puts the strip on the page's side (tab bar below a top toolbar, above a bottom one).
    static func stripSitsInBand(strip: TabBarPosition, toolbar: ToolbarPosition, order: TabBarOrder) -> Bool {
        switch (strip, toolbar) {
        case (.top, .top): order == .belowToolbar
        case (.bottom, .bottom): order == .aboveToolbar
        default: false
        }
    }

    /// The strip's and "…"'s frames on a band: the strip from the pane's leading edge to "…", "…"
    /// `tools` wide at the trailing edge, both on the band's line and as tall as it.
    static func bandFrames(band: CGRect, width: CGFloat, tools: CGFloat) -> (strip: CGRect, tools: CGRect) {
        let tools = min(max(0, tools), max(0, width))
        return (CGRect(x: 0, y: band.minY, width: width - tools, height: band.height),
                CGRect(x: width - tools, y: band.minY, width: tools, height: band.height))
    }

    /// Hands `toolbarPosition` to the content on screen; a parked view takes it when shown again.
    func applyToolbarPosition() {
        guard hostsContent, let host = content as? any ToolbarEdgeHosting else { return }
        host.toolbarPosition = toolbarPosition
    }

    /// Moves the strip into or out of a band after a show, a detach, a
    /// setting change or a window move. Never runs from `layout()`.
    func updateBand() {
        let wanted = wantedBandHost
        if let current = bandHost, current !== wanted {
            releaseBand()
            // A view another pane took keeps that pane's band (v4 review e).
            if let view = current as? NSView, view.superview == nil || view.superview === contentHost {
                current.onPaneHeaderBandLayout = nil
                current.onPaneHeaderBandRelease = nil
                current.onPaneHeaderBandReattach = nil
                current.setPaneHeaderBandHeight(0)
            }
            bandHost = nil
        }
        if let wanted {
            bandHost = wanted
            wanted.onPaneHeaderBandRelease = { [weak self] in self?.releaseBand() }
            // Crash recovery puts the browser back in this pane: take the band again.
            wanted.onPaneHeaderBandReattach = { [weak self] in self?.updateBand() }
            takeBand()
        }
        // Every caller changed what the pane shows or where its strip goes (a show, a detach, a window move).
        // invalidate: the strip, ring and tag are placed again.
        needsLayout = true
    }

    /// Frames the strip on the band once the browser and this pane share a
    /// window (v4 note 1), opens the band at the strip's height, follows the
    /// browser's layout passes, and orders VoiceOver from the top: toolbar,
    /// strip, page (or page, strip, toolbar).
    private func takeBand() {
        guard !isBandActive, let host = bandHost, let view = host as? NSView, let window, view.window === window,
              view.isDescendant(of: self) else { return }
        host.setPaneHeaderBandHeight(stripHeight)
        bandRect = host.paneHeaderBandRect
        host.onPaneHeaderBandLayout = { [weak self] rect in self?.bandDidLayout(rect) }
        layoutBandStrip()
        let strip: [Any] = [stripView] + (toolbar.map { [$0.view] } ?? [])
        setAccessibilityChildren(toolbarPosition == .top
            ? host.paneHeaderAccessibilityElements + strip + host.paneContentAccessibilityElements
            : host.paneContentAccessibilityElements + strip + host.paneHeaderAccessibilityElements)
    }

    /// The browser's layout pass placed the band (its animated passes too): the strip follows in the
    /// same pass, inside the same animation group.
    private func bandDidLayout(_ rect: CGRect) {
        guard isBandActive else { return }
        bandRect = rect
        layoutBandStrip()
    }

    /// Frames the strip and "…" on the band as it was last reported (`bandRect`), in this pane's
    /// coordinates. Runs from this pane's `layout()` and from the browser's.
    func layoutBandStrip() {
        guard let rect = bandRect, let view = bandHost as? NSView else { return }
        let band = convert(rect, from: view)
        let frames = Self.bandFrames(band: band, width: bounds.width, tools: toolbarWidth(shown: band.height))
        if stripView.frame != frames.strip { stripView.frame = frames.strip }
        if let tools = toolbar?.view, tools.frame != frames.tools {
            tools.frame = frames.tools
            tools.refreshCorner() // "…"'s hover spans the strip's frame
        }
    }

    /// Stops framing the strip on the band (idempotent): the strip goes back
    /// to the pane's own frame layout and VoiceOver to the default order. The
    /// band closes while the browser is still this pane's.
    func releaseBand() {
        guard isBandActive else { return }
        bandRect = nil
        setAccessibilityChildren(nil)
        if let host = bandHost, let view = host as? NSView, view.superview === contentHost { host.setPaneHeaderBandHeight(0) }
        needsLayout = true // invalidate: the strip left the band (the guard above) and goes back to frame layout.
    }

    /// The strip height changed (density, metrics, scale): the band follows.
    func refreshBandHeight() {
        guard isBandActive else { return }
        bandHost?.setPaneHeaderBandHeight(stripHeight)
    }
}
