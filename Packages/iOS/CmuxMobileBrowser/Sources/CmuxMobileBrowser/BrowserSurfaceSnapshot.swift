import Foundation

/// The durable, public-data subset of one phone-local workspace browser.
///
/// WebKit's opaque interaction state is intentionally excluded because it is
/// only valid for in-process remounts. A cold launch reloads the last committed
/// URL and lets the new `WKWebView` build its own history.
public struct BrowserSurfaceSnapshot: Codable, Equatable, Sendable {
    /// The stable owning workspace identity.
    public let workspaceID: String
    /// The browser surface identity.
    public let surfaceID: String
    /// The last committed page URL.
    public let currentURL: String?
    /// The last committed page title.
    public let title: String?
    /// The persisted content-mode preference.
    public let contentMode: String
    /// Whether the browser is the workspace's selected surface.
    public let isSelected: Bool
}
