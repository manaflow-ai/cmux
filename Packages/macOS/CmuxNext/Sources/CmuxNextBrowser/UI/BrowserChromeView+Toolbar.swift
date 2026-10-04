import AppKit
import CmuxNextDesign

// The toolbar row hides while the page is in pane fullscreen.
extension BrowserChromeView {
    func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        isToolbarHidden = hidden
        let height = hidden ? 0 : currentToolbarHeight
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        Motion.animateTimed(hidden ? .disappear : .appear, {
            self.toolbarHeight.animator().constant = height
            self.layoutSubtreeIfNeeded()
        }, completion: {
            if self.isToolbarHidden {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        })
    }
}
