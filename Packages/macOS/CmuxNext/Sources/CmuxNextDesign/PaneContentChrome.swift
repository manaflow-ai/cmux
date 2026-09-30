public import CoreGraphics

/// A pane's hosted view whose content area (the terminal surface or the web
/// page) sits below a header (the tab strip, a browser toolbar). The layout
/// draws the pane border, focus ring and rounded corners around the content
/// area only (user, nxdog9: "our rounded border needs to be drawn only
/// around the browser/terminal area, not around the omnibar as well"), and
/// the view rounds its own content area, so a Chromium page (a child window
/// the layout's clip cannot reach) finds the rounded ancestor it masks to.
@MainActor
public protocol PaneContentChrome: AnyObject {
    /// Points from the view's top edge to its content area.
    var paneHeaderHeight: CGFloat { get }
    /// Called whenever `paneHeaderHeight` changes (a toolbar hides, the tab
    /// strip height token changes, another tab's content is shown).
    var onPaneHeaderHeightChange: (() -> Void)? { get set }
    /// Rounds the content area's corners with `radius` (0 is square).
    func setPaneContentCornerRadius(_ radius: CGFloat)
}
