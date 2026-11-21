public import AppKit

/// A child panel that takes the mouse for the window's own content, such as a divider's mouse catcher over a page.
///
/// The overlay host keeps these above the page windows and below its overlay panel
/// (``WindowOverlayHost/reassertOrder()``). Other app panels at the panel's level go above the overlay panel. A
/// mouse catcher above it took the pointer from a toast over a divider: the divider's resize cursor showed on the
/// toast, and a drag that started on the toast resized the panes (user 2026-11-16).
public protocol UnderOverlayWindow: NSWindow {}
