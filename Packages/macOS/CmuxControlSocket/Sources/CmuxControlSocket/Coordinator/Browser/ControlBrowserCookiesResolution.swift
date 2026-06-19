public import Foundation

/// The outcome of `browser.cookies.get`, the typed twin of the legacy
/// `TerminalController.v2BrowserCookiesGet(params:)` body.
///
/// The witness resolves the browser panel, reads the cookie store (with the
/// legacy 3s timeout), and applies the `name`/`domain`/`path` filters; the
/// coordinator shapes the identity payload plus the `cookies` array.
public enum ControlBrowserCookiesGetResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The cookie-store read timed out (`timeout` / "Timed out reading
    /// cookies").
    case timedOut
    /// Resolved: the owning workspace, the resolved surface, and the
    /// filter-applied cookies.
    case resolved(workspaceID: UUID, surfaceID: UUID, cookies: [ControlBrowserCookie])
}

/// The outcome of `browser.cookies.set`, the typed twin of the legacy
/// `TerminalController.v2BrowserCookiesSet(params:)` body.
public enum ControlBrowserCookiesSetResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// No cookies payload was supplied (`invalid_params` / "Missing cookies
    /// payload").
    case missingPayload
    /// A cookie row could not be reconstructed into an `HTTPCookie`
    /// (`invalid_params` / "Invalid cookie payload", data `{"cookie": …}`).
    case invalidCookie(row: JSONValue)
    /// Setting a cookie timed out (`timeout` / "Timed out setting cookie",
    /// data `{"name": …}`).
    case timedOut(cookieName: String)
    /// Resolved: the owning workspace, the resolved surface, and the count of
    /// cookies set.
    case resolved(workspaceID: UUID, surfaceID: UUID, setCount: Int)
}

/// The outcome of `browser.cookies.clear`, the typed twin of the legacy
/// `TerminalController.v2BrowserCookiesClear(params:)` body.
public enum ControlBrowserCookiesClearResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The cookie-store read timed out (`timeout` / "Timed out reading
    /// cookies").
    case timedOut
    /// Resolved: the owning workspace, the resolved surface, and the count of
    /// cookies cleared.
    case resolved(workspaceID: UUID, surfaceID: UUID, cleared: Int)
}
