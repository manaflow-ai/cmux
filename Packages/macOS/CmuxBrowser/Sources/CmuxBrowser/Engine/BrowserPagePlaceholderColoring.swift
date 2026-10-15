public import AppKit

/// A page whose content view shows a color of its own until the page draws
/// its first frame (a Chromium page's host view, before its window paints).
///
/// The panel sets the theme background here so a new page opens on the
/// pane's color instead of flashing gray. The page's own document background
/// is not affected: an unstyled page still paints white, as in Chrome.
@MainActor
public protocol BrowserPagePlaceholderColoring: AnyObject {
    /// The color shown before the page's first frame.
    var placeholderColor: NSColor { get set }
}
