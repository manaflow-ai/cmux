/// The outcome of the app-side `browser.cookies.get` read.
public enum ControlBrowserCookiesGetResolution: Sendable, Equatable {
    /// The browser surface did not resolve.
    case failure(ControlBrowserPanelFailure)
    /// The cookie store read timed out (legacy `timeout` /
    /// "Timed out reading cookies").
    case timedOut
    /// All cookies in the panel's store (the coordinator filters).
    case cookies(identity: ControlBrowserPanelIdentity, cookies: [ControlBrowserCookie])
}
