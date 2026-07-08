internal import Foundation

/// The outcome of the v1 line-protocol `is_webview_focused` query.
public enum ControlBrowserPanelWebViewFocusState: Sendable, Equatable {
    /// The panel did not resolve to a browser panel of the selected workspace.
    case panelNotFound
    /// Whether the web view holds focus (`false` also covers a detached web
    /// view, matching the legacy reply).
    case focused(Bool)
}
