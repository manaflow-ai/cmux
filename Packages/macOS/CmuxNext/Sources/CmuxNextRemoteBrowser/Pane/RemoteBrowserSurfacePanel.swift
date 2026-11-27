public import AppKit
public import CmuxNextDesign

#if DEBUG
/// The window of one popup surface (a date picker, autofill list or
/// extension popup) of a remote tab: a `ContentChildPanel` of the page's
/// window at the surface's anchor. A child window is not clipped by the page
/// or the window, so a popup near the page edge shows in full. It is page
/// content for the overlay host (below app overlays), never key or main
/// (keys stay with the page, which routes them to the open popup), and
/// `RemoteBrowserSurfaces` places it again when the page moves inside the
/// window.
public final class RemoteBrowserSurfacePanel: ContentChildPanel {
    init(content: NSView) {
        super.init()
        content.autoresizingMask = [.width, .height]
        contentView = content
        // `debug.window_list` kind `remote-browser-surface`.
        identifier = NSUserInterfaceItemIdentifier("cmux.remote-browser-surface")
        setAccessibilityElement(false)
    }
}
#endif
