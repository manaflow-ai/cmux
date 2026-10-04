import AppKit
import CmuxNextDesign

// R109 `tabs.barOrder` below the toolbar: with the strip on top and a
// browser tab shown, the browser opens a band under its toolbar rows
// (`PaneHeaderBandHosting`) and the strip pins to that band's layout guide,
// so it moves in the toolbar's animation frames without changing parent.
// The pins end before the browser leaves the pane on every path: this
// pane's show and detach, and the browser's own viewWillMove hooks
// (`onPaneHeaderBandRelease`, v4 review).
extension PaneContentView {
    /// The band host this pane wants now; nil keeps the strip in its frame.
    private var wantedBandHost: (any PaneHeaderBandHosting)? {
        guard barOrder == .belowToolbar, barPosition == .top, hostsContent else { return nil }
        return content as? any PaneHeaderBandHosting
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
                current.setPaneHeaderBandHeight(0)
            }
            bandHost = nil
        }
        if let wanted {
            bandHost = wanted
            wanted.onPaneHeaderBandRelease = { [weak self] in self?.releaseBand() }
            pinBand()
        }
        needsLayout = true
    }

    /// Pins the strip to the band once the browser and this pane share a
    /// window (v4 note 1), opens the band at the strip's height and orders
    /// VoiceOver: toolbar, strip, page.
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
            stripView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(bandPins)
        setAccessibilityChildren(host.paneHeaderAccessibilityElements + [stripView] + host.paneContentAccessibilityElements)
    }

    /// Ends the pins (idempotent): the strip goes back to frame layout and
    /// VoiceOver to the default order. The band closes while the browser
    /// is still this pane's.
    func releaseBand() {
        guard !bandPins.isEmpty else { return }
        NSLayoutConstraint.deactivate(bandPins)
        bandPins = []
        stripView.translatesAutoresizingMaskIntoConstraints = true
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
