package import Foundation

/// A web notification a page showed (`BrowserTabIntent.webNotification`).
public struct BrowserWebNotification {
    public let title: String
    public let body: String
    /// The page's site as the banner names it ("example.com",
    /// "127.0.0.1:8080"): a page cannot pose as another site.
    public let site: String
    /// Runs the page's click handler (the notification's `click` event).
    public let click: @MainActor () -> Void

    public init(title: String, body: String, site: String, click: @escaping @MainActor () -> Void) {
        self.title = title
        self.body = body
        self.site = site
        self.click = click
    }
}
