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
        let height = hidden ? 0 : currentToolbarHeight
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        Motion.overlays.animateTimed(hidden ? .disappear : .appear, in: self, {
            // Outside a window no display runs the animation, so set the constant directly.
            (self.window == nil ? self.toolbarHeight : Motion.animator(self.toolbarHeight, in: self)).constant = height
            self.layoutSubtreeIfNeeded()
        }, completion: {
            if self.isToolbarHidden {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        })
    }
}
