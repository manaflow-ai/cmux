/// The parsed input for one worker-lane `browser.*` navigation command
/// (`browser.navigate` / `browser.back` / `browser.forward` / `browser.reload`),
/// handed from ``ControlBrowserNavigationWorker`` to the
/// ``ControlBrowserNavigationReading`` seam.
///
/// The worker owns the param parsing (the byte-faithful twin of `v2String` for
/// the `url` leaf); this value carries exactly the inputs the legacy
/// `TerminalController.v2BrowserNavigate` / `v2BrowserNavSimple` bodies acted on.
/// The seam (app side) resolves the `TabManager`, resolves `surface_id` against
/// the god-owned handle registry, resolves the workspace and browser panel,
/// performs the navigation on the live `BrowserPanel`, builds the identity
/// payload, and runs the optional post-action accessibility snapshot.
///
/// `params` is carried verbatim because the app-side resolution head
/// (`v2ResolveTabManager` / `v2ResolveWorkspace` / `v2UUID(_:"surface_id")`,
/// which can resolve a handle ref) and the post-snapshot walk
/// (`v2BrowserAppendPostSnapshot`) read routing selectors and `snapshot_*` flags
/// from it with a precedence terminal-style routing selectors cannot express.
public enum ControlBrowserNavigationRequest: Sendable {
    /// `browser.navigate` — load `url` in the resolved browser surface. `url` is
    /// the worker-parsed (`v2String`) value; the seam returns
    /// ``ControlBrowserNavigationResolution/missingURL`` when it is `nil`,
    /// preserving the legacy order (the `url` check followed `TabManager` and
    /// `surface_id` resolution).
    case navigate(params: [String: JSONValue], url: String?)
    /// `browser.back` — go back in the resolved browser surface's history.
    case back(params: [String: JSONValue])
    /// `browser.forward` — go forward in history.
    case forward(params: [String: JSONValue])
    /// `browser.reload` — reload the current page.
    case reload(params: [String: JSONValue])

    /// The carried routing/snapshot params, common to every case.
    public var params: [String: JSONValue] {
        switch self {
        case let .navigate(params, _),
             let .back(params),
             let .forward(params),
             let .reload(params):
            return params
        }
    }

    /// The worker-parsed target URL for `browser.navigate`, `nil` for the other
    /// cases (which take no URL).
    public var navigateURL: String? {
        if case let .navigate(_, url) = self { return url }
        return nil
    }
}
