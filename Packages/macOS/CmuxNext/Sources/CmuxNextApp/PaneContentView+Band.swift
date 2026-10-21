import AppKit
import CmuxNextDesign

// R109 `tabs.barOrder`: with the strip and a browser's toolbar on one edge
// (`tabs.barPosition`, `browser.toolbarPosition`) and the strip between the
// toolbar and the page (below a top toolbar, above a bottom one), the browser
// opens a band beside its toolbar rows (`PaneHeaderBandHosting`) and the strip
// pins to that band's layout guide, so it moves in the toolbar's animation
// frames without changing parent.
// The pins end before the browser leaves the pane on every path: this
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
                current.onPaneHeaderBandRelease = nil
                current.onPaneHeaderBandReattach = nil
                current.setPaneHeaderBandHeight(0)
            }
            bandHost = nil
        }
        if let wanted {
            bandHost = wanted
            wanted.onPaneHeaderBandRelease = { [weak self] in self?.releaseBand() }
            // Crash recovery puts the browser back in this pane: re-pin.
            wanted.onPaneHeaderBandReattach = { [weak self] in self?.updateBand() }
            pinBand()
        }
        needsLayout = true
    }

    /// Pins the strip to the band once the browser and this pane share a
    /// window (v4 note 1), opens the band at the strip's height and orders
    /// VoiceOver from the top: toolbar, strip, page (or page, strip, toolbar).
    private func pinBand() {
        guard bandPins.isEmpty, let host = bandHost, let view = host as? NSView, let window, view.window === window,
              view.isDescendant(of: self) else { return }
        host.setPaneHeaderBandHeight(stripHeight)
        stripView.translatesAutoresizingMaskIntoConstraints = false
        let guide = host.paneHeaderBandGuide
        bandPins = [
            stripView.topAnchor.constraint(equalTo: guide.topAnchor),
            stripView.heightAnchor.constraint(equalTo: guide.heightAnchor),
            stripView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripView.trailingAnchor.constraint(equalTo: toolbar?.view.leadingAnchor ?? trailingAnchor),
        ] + toolbarBandPins()
        NSLayoutConstraint.activate(bandPins)
        let strip: [Any] = [stripView] + (toolbar.map { [$0.view] } ?? [])
        setAccessibilityChildren(toolbarPosition == .top
            ? host.paneHeaderAccessibilityElements + strip + host.paneContentAccessibilityElements
            : host.paneContentAccessibilityElements + strip + host.paneHeaderAccessibilityElements)
    }

    /// Ends the pins (idempotent): the strip goes back to frame layout and
    /// VoiceOver to the default order. The band closes while the browser
    /// is still this pane's.
    func releaseBand() {
        guard !bandPins.isEmpty else { return }
        NSLayoutConstraint.deactivate(bandPins)
        bandPins = []
        stripView.translatesAutoresizingMaskIntoConstraints = true
        toolbar?.view.translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityChildren(nil)
        if let host = bandHost, let view = host as? NSView, view.superview === contentHost { host.setPaneHeaderBandHeight(0) }
        needsLayout = true
    }

    /// The strip height changed (density, metrics, scale): the band follows.
    func refreshBandHeight() {
        guard isBandActive else { return }
        bandHost?.setPaneHeaderBandHeight(stripHeight)
    }
}

