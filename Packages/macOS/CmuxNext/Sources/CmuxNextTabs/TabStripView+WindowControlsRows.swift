public import AppKit

extension TabStripView {
    /// The views the strip's window controls inset places (``updateWindowControlsAvoidance()``): the
    /// tabs' clip and the + button after the last tab. A change of the window's top row (the toolbar
    /// band opening over a hidden sidebar) lays the strip out once and springs these from where they
    /// showed on the render server.
    public var windowControlsRows: [NSView] { [tabsClip, newTabButton] }
}
