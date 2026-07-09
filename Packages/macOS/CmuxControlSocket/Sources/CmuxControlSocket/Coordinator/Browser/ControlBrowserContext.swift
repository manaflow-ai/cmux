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

    /// `browser.network.route` / `browser.network.unroute` — append one
    /// not-supported network-interception attempt to the per-surface ring log
    /// the app keeps (capped at 256 entries, cleared on surface teardown). The
    /// witness stores `["action": action, "params": <params>]`, byte-faithful to
    /// the legacy `v2BrowserRecordUnsupportedRequest`. `params` is the original
    /// request param object.
    func controlBrowserRecordUnsupportedNetworkRequest(
        surfaceID: UUID,
        action: String,
        params: [String: JSONValue]
    )

    /// `browser.network.requests` — the recorded not-supported network-request
    /// log for `surfaceID` (the legacy
    /// `v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []`), as wire
    /// values. Empty when nothing has been recorded for the surface.
    func controlBrowserUnsupportedNetworkRequests(surfaceID: UUID) -> [JSONValue]

    /// `browser.addinitscript` — register a document-start init script on the
    /// resolved browser and evaluate it once. `script` is the validated, present
    /// `script`/`content` param. The witness resolves the panel through the
    /// shared `v2BrowserWithPanel` head, appends to the per-surface init-script
    /// cache, registers the `WKUserScript`, and runs the script once.
    func controlBrowserAddInitScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddInitScriptResolution

    /// `browser.addscript` — evaluate a one-shot script on the resolved browser.
    /// `script` is the validated, present `script`/`content` param.
    func controlBrowserAddScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddScriptResolution

    /// `browser.addstyle` — register a document-start `<style>`-injecting init
    /// script on the resolved browser and evaluate it once. `css` is the
    /// validated, present `css`/`style`/`content` param.
    func controlBrowserAddStyle(
        params: [String: JSONValue],
        css: String
    ) -> ControlBrowserAddStyleResolution

    /// `browser.dialog.accept` / `browser.dialog.dismiss` — shift the front entry
    /// off the resolved browser's in-page dialog queue and record the chosen
    /// default. `accept` is the accept/dismiss intent; `text` is the optional
    /// `text`/`prompt_text` param used as the prompt default when accepting.
    func controlBrowserDialogRespond(
        params: [String: JSONValue],
        accept: Bool,
        text: String?
    ) -> ControlBrowserDialogRespondResolution

    /// `browser.import.dialog` — validate the `scope` / `destination_profile`
    /// params and schedule the browser data-import dialog presentation. The
    /// witness owns all validation and the `BrowserProfileStore` lookup/create;
    /// the coordinator only re-emits the typed failure categories.
    func controlBrowserImportDialog(
        params: [String: JSONValue]
    ) -> ControlBrowserImportDialogResolution

    /// `browser.get.title` — read the resolved browser panel's page title. The
    /// witness resolves the panel through the shared `v2BrowserWithPanel` head
    /// (`surface_id`/`tab_id`/`pane_id` precedence) and reads `pageTitle`.
    func controlBrowserGetTitle(
        params: [String: JSONValue]
    ) -> ControlBrowserGetTitleResolution

    /// `browser.frame.select` — pin the resolved surface to a same-origin iframe.
    /// `rawSelector` is the validated, present `selector`/`sel`/`element_ref`/`ref`
    /// param; the witness resolves it (including `@e` element refs) against the
    /// surface, evaluates the same-origin probe, and on success records the frame
    /// selector in the per-surface cache.
    func controlBrowserFrameSelect(
        params: [String: JSONValue],
        rawSelector: String
    ) -> ControlBrowserFrameSelectResolution

    /// `browser.frame.main` — clear the resolved surface's pinned frame selector,
    /// returning page-level evaluation to the main frame.
    func controlBrowserFrameMain(
        params: [String: JSONValue]
    ) -> ControlBrowserFrameMainResolution

    /// `browser.screenshot` — capture the resolved browser's automation-visible
    /// viewport as PNG. The witness resolves the panel, captures the snapshot
    /// (15s budget), encodes the PNG, and best-effort writes a pruned temp file;
    /// the coordinator shapes the identity payload plus `png_base64`/`path`/`url`.
    func controlBrowserScreenshot(
        params: [String: JSONValue]
    ) -> ControlBrowserScreenshotResolution

    /// `browser.console.list` / `browser.console.clear` — read (and optionally
    /// clear) the resolved browser's captured console-log ring. The witness
    /// resolves the panel through the shared `v2BrowserWithPanel` head, installs
    /// the telemetry hooks, and evaluates the read/clear script; `clear` is the
    /// effective flag (the coordinator forces it `true` for
    /// `browser.console.clear`). The coordinator shapes the identity payload plus
    /// the `entries` array and `count`.
    func controlBrowserConsoleList(
        params: [String: JSONValue],
        clear: Bool
    ) -> ControlBrowserConsoleListResolution

    /// `browser.errors.list` — read (and optionally clear) the resolved
    /// browser's captured uncaught-error ring. The witness resolves the panel,
    /// installs the telemetry hooks, and evaluates the read/clear script; `clear`
    /// is the `clear` param. The coordinator shapes the identity payload plus the
    /// `errors` array and `count`.
    func controlBrowserErrorsList(
        params: [String: JSONValue],
        clear: Bool
    ) -> ControlBrowserErrorsListResolution

    /// `browser.state.save` — snapshot the resolved browser's URL, cookies,
    /// `localStorage`/`sessionStorage`, and pinned frame selector to a JSON file.
    /// `path` is the validated, present `path` param (the coordinator emits the
    /// `Missing path` error). The witness performs the storage read, cookie read,
    /// and atomic file write; the coordinator shapes the identity payload plus
    /// `path`/`cookies`.
    func controlBrowserStateSave(
        params: [String: JSONValue],
        path: String
    ) -> ControlBrowserStateSaveResolution

    /// `browser.state.load` — restore the resolved browser's frame selector,
    /// navigation, cookies, and `localStorage`/`sessionStorage` from a JSON state
    /// file. `path` is the validated, present `path` param (the coordinator emits
    /// the `Missing path` error). The witness reads + parses the file (its
    /// read/parse failures precede panel resolution), reproduces the
    /// `v2BrowserWithPanel` head, and applies the restore; the coordinator shapes
    /// the identity payload plus `path`/`loaded`.
    func controlBrowserStateLoad(
        params: [String: JSONValue],
        path: String
    ) -> ControlBrowserStateLoadResolution

    /// `browser.tab.list` — enumerate the routed workspace's ordered browser
    /// panels. The witness reproduces the `v2ResolveTabManager` →
    /// `v2ResolveWorkspace` head and reads each panel's id/title/url/focus plus
    /// its owning pane; the coordinator shapes the identity payload plus the
    /// `tabs` array.
    func controlBrowserTabList(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabListResolution

    /// `browser.tab.new` — create a browser surface in the routed workspace's
    /// target pane. `rawURLString` is the raw `url` param; the witness parses it,
    /// applies the disabled-browser external-open fallback, resolves the target
    /// pane (`pane_id`/`target_pane_id`/`surface_id`-owning pane/focused), and
    /// creates the surface. The coordinator shapes the identity payload.
    func controlBrowserTabNew(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors,
        rawURLString: String?
    ) -> ControlBrowserTabNewResolution

    /// `browser.tab.switch` — focus a target browser surface in the routed
    /// workspace. The witness reproduces the head, resolves the target
    /// (explicit `target_surface_id`/`tab_id`, then `index`, then `surface_id`),
    /// and focuses it; the coordinator shapes the identity payload.
    func controlBrowserTabSwitch(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabSwitchResolution

    /// `browser.tab.close` — close a target browser surface in the routed
    /// workspace, recording history. The witness reproduces the head, resolves
    /// the target (explicit `target_surface_id`/`tab_id`, then `index`, then
    /// `surface_id`, then the focused panel), enforces the last-surface guard,
    /// and closes it; the coordinator shapes the identity payload.
    func controlBrowserTabClose(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabCloseResolution
}
