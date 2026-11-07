public import AppKit

/// A React surface of the browser chrome (webviews/src/pages/<page>), drawn by the page host (CmuxNextPages'
/// `BrowserChromeWebHost`). The owner pushes state; the page sends commands and the
/// size its content needs.
@MainActor
public protocol BrowserChromeWebContent: AnyObject {
    /// The transparent web view, placed inside the owner's own glass.
    var view: NSView { get }
    /// The page's next state (JSON object).
    func push(_ state: [String: Any])
    /// A message from the page: `command` (a `{type, ...}` object) or `size` (`{width, height}`).
    var onMessage: ((_ kind: String, _ params: [String: Any]) -> Void)? { get set }
    /// Gives the page the keys.
    func focus()
    /// The surface closes for good.
    func close()
}

/// The surfaces the browser chrome draws in React.
public enum BrowserChromeWebPage: String, Sendable {
    case pageInfo = "page-info"
    /// Page Info's Site settings window (one origin's usage and permissions).
    case siteSettings = "site-settings"
    /// Page Info's On-device site data window.
    case siteData = "site-data"
    /// Page Info's certificate viewer window.
    case certificate
}
