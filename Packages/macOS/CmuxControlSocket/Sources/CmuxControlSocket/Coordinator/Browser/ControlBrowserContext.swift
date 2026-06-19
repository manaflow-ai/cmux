public import Foundation

/// The v2 browser-panel/lifecycle slice of the control-command seam (a
/// constituent of the ``ControlCommandContext`` umbrella): live app reach for
/// the non-JS-evaluating, main-actor `browser.*` methods
/// (`browser.open_split` / `browser.react_grab.toggle` /
/// `browser.devtools.toggle` / `browser.console.show` /
/// `browser.focus_mode.set` / `browser.zoom.set` / `browser.history.clear` /
/// `browser.url.get` / `browser.focus_webview` / `browser.is_webview_focused`).
///
/// Distinct from ``ControlBrowserPanelContext``, which serves the v1
/// line-protocol browser commands. The JS-evaluating `browser.*` methods
/// (`navigate`/`screenshot`/`cookies.*`/…) are NOT here: PR 5778 moved them
/// onto the socket-worker lane, which the `@MainActor` coordinator cannot host,
/// so they stay on the app-side dispatcher.
///
/// `@MainActor` because its conformer lives on the main actor and the
/// coordinator runs there too. The coordinator owns all param parsing,
/// validation, and ``JSONValue`` payload shaping; these witnesses perform the
/// live `TabManager` / `Workspace` / `BrowserPanel` reach and return typed
/// Sendable resolution values, byte-faithful to the legacy `v2Browser*` bodies.
@MainActor
public protocol ControlBrowserContext: AnyObject {
    /// Whether the routed `TabManager` resolves (the legacy
    /// `guard let tabManager = v2ResolveTabManager(params:)` head shared by
    /// every browser body).
    func controlBrowserRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool

    /// `browser.open_split` — create a browser split off the focused panel,
    /// after the app-side URL/diff-viewer/availability resolution.
    ///
    /// - Parameters:
    ///   - routing: The window/workspace routing selectors.
    ///   - rawURLString: The raw `url` param (already trimmed-or-`nil` upstream
    ///     is not assumed; the witness re-runs the legacy smart resolution).
    ///   - respectExternalOpenRules: The `respect_external_open_rules` flag.
    ///   - diffViewerToken: The `diff_viewer_token` param, if present.
    ///   - diffViewerFiles: The `diff_viewer_files` raw allowlist as wire
    ///     values, if present; the witness reconstitutes the Foundation array.
    ///   - explicitSourceSurfaceID: The `surface_id` param resolved to a UUID.
    ///   - requestedFocus: The `focus` param.
    ///   - showOmnibar: The `show_omnibar` param (defaulted upstream to `true`).
    ///   - transparentBackground: The `transparent_background` param.
    ///   - bypassRemoteProxyParam: The `bypass_remote_proxy` param, if present.
    func controlBrowserOpenSplit(
        routing: ControlRoutingSelectors,
        rawURLString: String?,
        respectExternalOpenRules: Bool,
        diffViewerToken: String?,
        diffViewerFiles: [JSONValue]?,
        explicitSourceSurfaceID: UUID?,
        requestedFocus: Bool,
        showOmnibar: Bool,
        transparentBackground: Bool,
        bypassRemoteProxyParam: Bool?
    ) -> ControlBrowserOpenSplitResolution

    /// `browser.react_grab.toggle` — toggle React Grab on the resolved browser
    /// surface. `browserSurfaceID`/`returnSurfaceID` are the parsed
    /// `surface_id`/`return_to` selectors.
    func controlBrowserReactGrabToggle(
        routing: ControlRoutingSelectors,
        browserSurfaceID: UUID?,
        returnSurfaceID: UUID?
    ) -> ControlBrowserActionResolution

    /// `browser.devtools.toggle` — toggle Web Inspector on the focused-or-named
    /// browser. `explicitSurfaceID` is the `surface_id` selector;
    /// `surfaceWasSupplied` distinguishes an absent param from a present one.
    func controlBrowserDevToolsToggle(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> ControlBrowserActionResolution

    /// `browser.console.show` — open the Web Inspector console.
    func controlBrowserConsoleShow(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> ControlBrowserActionResolution

    /// `browser.focus_mode.set` — enter/exit/toggle browser focus mode.
    /// `intent` is the validated mode intent.
    func controlBrowserFocusModeSet(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool,
        intent: ControlBrowserFocusModeIntent
    ) -> ControlBrowserActionResolution

    /// `browser.zoom.set` — zoom in/out/reset. `direction` is validated.
    func controlBrowserZoomSet(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool,
        direction: ControlBrowserZoomDirection
    ) -> ControlBrowserActionResolution

    /// `browser.history.clear` — clear the default profile's browser history
    /// (the destructive `force=true` guard is enforced upstream).
    func controlBrowserClearDefaultHistory()

    /// `browser.url.get` — the resolved browser surface's current URL.
    /// `surfaceID` is the required `surface_id` selector.
    func controlBrowserCurrentURL(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserURLResolution

    /// `browser.focus_webview` — move first responder into the web view.
    func controlBrowserFocusWebView(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserFocusWebViewResolution

    /// `browser.is_webview_focused` — whether the web view holds focus.
    func controlBrowserIsWebViewFocused(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserIsWebViewFocusedResolution

    /// `browser.cookies.get` — read the resolved browser's cookie store and
    /// apply the optional `name`/`domain`/`path` filters. `params` is the raw
    /// param object: the witness resolves the browser panel through the shared
    /// `v2BrowserWithPanel` head (`surface_id`/`tab_id`/`pane_id` precedence),
    /// which terminal-only routing selectors cannot express.
    func controlBrowserCookiesGet(
        params: [String: JSONValue],
        nameFilter: String?,
        domainFilter: String?,
        pathFilter: String?
    ) -> ControlBrowserCookiesGetResolution

    /// `browser.cookies.set` — set cookies on the resolved browser's store.
    /// `cookieRows` is the reconstituted cookie payload (the `cookies` array, or
    /// a single cookie assembled from the individual params); the witness bridges
    /// each row back to Foundation to build `HTTPCookie`s.
    func controlBrowserCookiesSet(
        params: [String: JSONValue],
        cookieRows: [JSONValue]
    ) -> ControlBrowserCookiesSetResolution

    /// `browser.cookies.clear` — delete matching cookies from the resolved
    /// browser's store. `clearAll` reproduces the legacy
    /// `all == nil && name == nil && domain == nil` clear-everything rule.
    func controlBrowserCookiesClear(
        params: [String: JSONValue],
        nameFilter: String?,
        domainFilter: String?,
        clearAll: Bool
    ) -> ControlBrowserCookiesClearResolution

    /// `browser.storage.get` — read `localStorage`/`sessionStorage`. `params` is
    /// the raw param object the witness feeds to the app-side
    /// `BrowserControlService.storageType(params:)`; `key` is the queried key.
    func controlBrowserStorageGet(
        params: [String: JSONValue],
        key: String?
    ) -> ControlBrowserStorageGetResolution

    /// `browser.storage.set` — write a `localStorage`/`sessionStorage` entry.
    /// `value` is the raw `value` param (normalized + JSON-literal-encoded by the
    /// witness); `key` is the validated, non-empty key.
    func controlBrowserStorageSet(
        params: [String: JSONValue],
        key: String,
        value: JSONValue
    ) -> ControlBrowserStorageSetResolution

    /// `browser.storage.clear` — clear `localStorage`/`sessionStorage`.
    func controlBrowserStorageClear(
        params: [String: JSONValue]
    ) -> ControlBrowserStorageClearResolution
}
