public import AppKit
public import CmuxNextDesignTokens

/// A pane content view that can open an empty band between its own header
/// rows (a browser's toolbar and bookmarks bar) and its content area, for
/// the pane's tab strip (`tabs.barOrder` below the toolbar, R109). The view
/// owns only the space and reports where it is after each of its layout
/// passes (`onPaneHeaderBandLayout`); the pane frames its strip there, so the
/// strip moves in the same animation frames as the header. The band is part
/// of `paneHeaderHeight`.
@MainActor
public protocol PaneHeaderBandHosting: PaneContentChrome {
    /// Opens the band at `height` points; 0 removes it.
    func setPaneHeaderBandHeight(_ height: CGFloat)
    /// The band in this view's coordinates, laid out first (the pane's first placement, tests).
    var paneHeaderBandRect: CGRect { get }
    /// Called at the end of each of this view's layout passes with the band in this view's
    /// coordinates, the passes inside the header's own animation included, so a strip framed
    /// from it in the call moves in the same animation group as the header.
    var onPaneHeaderBandLayout: ((CGRect) -> Void)? { get set }
    /// Called before this view leaves its superview or window, on every
    /// path (a pane's own detach, a renderer swap): the pane stops framing
    /// its strip on the band before the views part.
    var onPaneHeaderBandRelease: (() -> Void)? { get set }
    /// Called after this view is back in a superview inside a window (a
    /// renderer crash recovery removes it and adds it back), so the pane
    /// can take the band again through its normal path.
    var onPaneHeaderBandReattach: (() -> Void)? { get set }
    /// The accessibility elements of the header rows and of the content
    /// area, so the pane can order them toolbar, strip, page.
    var paneHeaderAccessibilityElements: [Any] { get }
    var paneContentAccessibilityElements: [Any] { get }
}
