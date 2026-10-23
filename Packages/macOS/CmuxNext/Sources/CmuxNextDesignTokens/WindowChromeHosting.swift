/// A window whose chrome state pages read (`PageWebView` sets `data-app-sidebar`).
@MainActor
public protocol WindowChromeHosting: AnyObject {
    /// The window's sidebar is hidden.
    var sidebarHidden: Bool { get }
}
