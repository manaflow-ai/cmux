/// The outcome of the app-side `browser.cookies.set` write, preserving the
/// legacy in-closure ordering: panel resolution first, then the empty-payload
/// check, then per-row validation/writes.
public enum ControlBrowserCookiesSetResolution: Sendable, Equatable {
    /// The browser surface did not resolve.
    case failure(ControlBrowserPanelFailure)
    /// No cookie rows after parsing (legacy `invalid_params` /
    /// "Missing cookies payload").
    case emptyPayload
    /// A row did not build an `HTTPCookie` (legacy `invalid_params` /
    /// "Invalid cookie payload", `data: {"cookie": row}`).
    case invalidCookie(row: JSONValue)
    /// A store write timed out (legacy `timeout` / "Timed out setting cookie",
    /// `data: {"name": …}`).
    case timedOutSetting(name: String)
    /// All rows wrote.
    case set(identity: ControlBrowserPanelIdentity, count: Int)
}
