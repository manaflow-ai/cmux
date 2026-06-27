public import Foundation

/// The window-portal embedding lifecycle signals broadcast over
/// `NotificationCenter`.
///
/// Each case owns the exact notification name string the app target previously
/// declared inline on `extension Notification.Name`. The post sites
/// (`BrowserWindowPortal`, `GhosttyTerminalView`) and the observe sites
/// (`Workspace+WorkspaceLayoutFollowUpHosting`, the UI-test recorders) stay
/// app-side; they reach the name through the `Notification.Name` accessors the
/// god still vends, which now forward to `notificationName` here so each wire
/// string lives in one place.
///
/// The wire shape is unchanged. The names are
/// `"cmux.terminalPortalVisibilityDidChange"` and
/// `"cmux.browserPortalRegistryDidChange"`, the latter posted with the
/// `WKWebView` as `object`.
public enum BrowserPortalSignal: Sendable {
    /// A hosted terminal portal's visibility changed.
    case terminalPortalVisibilityDidChange
    /// The browser window-portal registry gained or lost a web view.
    case browserPortalRegistryDidChange

    /// The `NotificationCenter` name for this signal.
    public var notificationName: Notification.Name {
        switch self {
        case .terminalPortalVisibilityDidChange:
            return Notification.Name("cmux.terminalPortalVisibilityDidChange")
        case .browserPortalRegistryDidChange:
            return Notification.Name("cmux.browserPortalRegistryDidChange")
        }
    }
}
