import AppKit
import CmuxNextDesign

/// An app screen's pane (app-screens.md 3) draws edge to edge without
/// chrome: no padding or rounding, and no ring, dim, border or tab emphasis.
extension ScreenContentView {
    /// The pane padding and corner radius of `pane`: none for an app screen's pane.
    func applyShape(_ pane: PaneID, style: LayoutStyle) {
        let bare = layout.chromelessPanes.contains(pane)
        context.hosts[pane]?.applyShape(padding: bare ? 0 : style.panePadding, cornerRadius: bare ? 0 : style.paneCornerRadius)
    }

    /// Gives an app screen's pane its overlay (only an unread attention mark
    /// shows) and returns true; false for any other pane, which keeps its chrome.
    func applyBareChrome(_ pane: PaneID, _ host: PaneHostView, attention: AttentionMark?, animated: Bool) -> Bool {
        guard layout.chromelessPanes.contains(pane) else { return false }
        let style = context.style
        host.setChrome(showsRing: false, dim: 0, focusRing: style.focusRing, tabEmphasis: .full,
                       border: PaneOverlayView.Border(shows: false, width: style.paneBorderWidth, color: style.paneBorderColor),
                       attention: attention, attentionSettings: style.attention, animated: animated)
        return true
    }
}
