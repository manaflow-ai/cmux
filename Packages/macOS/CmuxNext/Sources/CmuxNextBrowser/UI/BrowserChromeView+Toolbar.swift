import AppKit
import CmuxNextDesign

// The toolbar row hides while the page is in pane fullscreen, or while the
// person hid it (Toggle Omnibar).
extension BrowserChromeView {
    /// Toggle Omnibar (`palette.browserToggleOmnibar`): hides the address bar
    /// row of this tab, or shows it again. Pane fullscreen still hides it.
    public func toggleOmnibar() {
        isOmnibarHidden.toggle()
        setToolbarHidden(isOmnibarHidden || tab.state.isContentFullscreen)
    }

    func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        isToolbarHidden = hidden
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        // invalidate: the toolbar row's height in the layout changed (`toolbarRowHeight`).
        needsLayout = true
        Motion.overlays.animateTimed(hidden ? .disappear : .appear, in: self, {
            // The pane's strip on the band takes its frame in this pass too (`reportHeaderBandLayout`).
            // sync-layout: inside the animation group, so the rows' frames animate to the new toolbar height.
            self.layoutSubtreeIfNeeded()
        }, completion: {
            if self.isToolbarHidden {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        })
    }
}
