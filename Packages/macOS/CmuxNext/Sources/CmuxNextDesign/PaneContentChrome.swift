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
    /// The pane moved or resized in its window (layout step, sidebar show
    /// or hide, column scroll), so window-relative chrome can re-check
    /// itself (a tab strip under the traffic lights).
    func paneFrameInWindowDidChange()
    /// How strongly the view's own chrome (its tab strip) draws: full in
    /// the focused pane, subtle in the others (`appearance.focusIndicator`).
    func setChromeEmphasis(_ emphasis: ChromeEmphasis, animated: Bool)
}

extension PaneContentChrome {
    public func paneFrameInWindowDidChange() {}
    public func setChromeEmphasis(_ emphasis: ChromeEmphasis, animated: Bool) {}
}
