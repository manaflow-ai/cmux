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
    /// The state a reloaded page (a crashed renderer the host reloads) starts from, without a push to
    /// the running page: the toolbar keeps the field's unsent text in it as the person types.
    func keepForReload(_ state: [String: Any])
    /// A message from the page: `command` (a `{type, ...}` object) or `size` (`{width, height}`).
    var onMessage: ((_ kind: String, _ params: [String: Any]) -> Void)? { get set }
    /// Gives the page the keys.
    func focus()
    /// The view that holds the keys while the page has them.
    var focusView: NSView { get }
    /// Whether the page may take the keys now (nil: always, the default). The toolbar takes them only
    /// while its field edits, so a click on one of its buttons never moves them off the page.
    var acceptsKeyFocus: (() -> Bool)? { get set }
    /// The page's view stopped being first responder (the owner ends editing).
    var onResignedKeys: (() -> Void)? { get set }
    /// Edits the page's native context menu (the omnibar field's Paste and Go); nil keeps the default.
    var contextMenuEditor: (@MainActor (NSMenu) -> Void)? { get set }
    /// The surface closes for good.
    func close()
}

/// Only the toolbar's page gates the keys, edits its menu and keeps a reload state; any other page
/// (and a test's stand-in) takes the keys in its view, always, and keeps the defaults.
extension BrowserChromeWebContent {
    public func keepForReload(_ state: [String: Any]) {}
    public var focusView: NSView { view }
    public var acceptsKeyFocus: (() -> Bool)? {
        get { nil }
        set {}
    }
    public var onResignedKeys: (() -> Void)? {
        get { nil }
        set {}
    }
    public var contextMenuEditor: (@MainActor (NSMenu) -> Void)? {
        get { nil }
        set {}
    }
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
    /// The Import Cookies card at the bottom of a page (`BrowserCookieImportCard`).
    case cookieImport = "cookie-import"
    /// The browser toolbar row (`BrowserToolbarWebView`): one per pane, popup window or Markdown bar.
    case browserToolbar = "browser-toolbar"
    /// The omnibox suggestion card, in its own panel under the toolbar (`OmniboxPopupPanel`).
    case omniboxPopup = "omnibox-popup"
}
