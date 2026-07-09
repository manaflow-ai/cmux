internal import Foundation

/// The outcome of the v2 `browser.is_webview_focused`. The legacy body always
/// replies `{"focused": <bool>}` and never errors: an unresolved surface or a
/// detached web view both report `false`, matching the legacy reply.
public struct ControlBrowserIsWebViewFocusedResolution: Sendable, Equatable {
    /// Whether the web view holds first responder.
    public var focused: Bool

    /// Creates the resolution.
    public init(focused: Bool) {
        self.focused = focused
    }
}
