public import AppKit

public extension CALayer {
    /// The name of the layer mask the column strip puts on a pane that
    /// scrolled under a docked column or past the strip's edge
    /// (`PaneHostView.setStripClip`). A Chromium page is a child window that
    /// no layer mask reaches, so its clip shape reads this one by name
    /// (`CEFClipShape.clips(around:)`), not any other mask on an ancestor.
    static let cmuxStripClipName = "cmux.stripClip"
}
