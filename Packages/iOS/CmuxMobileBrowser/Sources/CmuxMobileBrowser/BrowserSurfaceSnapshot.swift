import Foundation

/// The durable, public-data subset of one phone-local workspace browser.
///
/// WebKit's opaque interaction state is intentionally excluded because it is
/// only valid for in-process remounts. A cold launch reloads the last committed
/// URL and lets the new `WKWebView` build its own history.
struct BrowserSurfaceSnapshot: Codable, Equatable, Sendable {
    let workspaceID: String
    let surfaceID: String
    let currentURL: String?
    let title: String?
    let contentMode: String
    let isSelected: Bool
}
