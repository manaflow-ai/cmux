public import AppKit

/// A pane content view that can open an empty band between its own header
/// rows (a browser's toolbar and bookmarks bar) and its content area, for
/// the pane's tab strip (`tabs.barOrder` below the toolbar, R109). The view
/// owns only the space: an `NSLayoutGuide` the pane pins its strip to, so
/// the strip moves in the same animation frames as the header. The band is
/// part of `paneHeaderHeight`.
@MainActor
public protocol PaneHeaderBandHosting: PaneContentChrome {
    /// Opens the band at `height` points; 0 removes it.
    func setPaneHeaderBandHeight(_ height: CGFloat)
    /// The band's space, for constraints from an ancestor's subview.
    var paneHeaderBandGuide: NSLayoutGuide { get }
    /// The band in this view's coordinates (tests, debug).
    var paneHeaderBandRect: CGRect { get }
    /// Called before this view leaves its superview or window, on every
    /// path (a pane's own detach, a renderer swap): constraints from the
    /// pane to `paneHeaderBandGuide` must end before the views part.
    var onPaneHeaderBandRelease: (() -> Void)? { get set }
    /// Called after this view is back in a superview inside a window (a
    /// renderer crash recovery removes it and adds it back), so the pane
    /// can pin again through its normal activate path.
    var onPaneHeaderBandReattach: (() -> Void)? { get set }
    /// The accessibility elements of the header rows and of the content
    /// area, so the pane can order them toolbar, strip, page.
    var paneHeaderAccessibilityElements: [Any] { get }
    var paneContentAccessibilityElements: [Any] { get }
}
