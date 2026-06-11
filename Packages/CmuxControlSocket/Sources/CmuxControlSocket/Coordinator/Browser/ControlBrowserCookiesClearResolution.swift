/// The outcome of the app-side `browser.cookies.clear` deletion pass.
public enum ControlBrowserCookiesClearResolution: Sendable, Equatable {
    /// The browser surface did not resolve.
    case failure(ControlBrowserPanelFailure)
    /// The cookie store read timed out (legacy `timeout` /
    /// "Timed out reading cookies").
    case timedOut
    /// The matching cookies were deleted.
    case cleared(identity: ControlBrowserPanelIdentity, removed: Int)
}
