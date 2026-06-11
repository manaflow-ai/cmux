public import Foundation

/// The browser-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella), covering the navigation / panel /
/// tabs / network / state half of `browser.*` (the DOM-element automation
/// commands are a separate domain).
///
/// The app target conforms by reading live `TabManager` / `Workspace` /
/// `BrowserPanel` / `WKWebView` state. Every method is `@MainActor` because
/// the conformer and the coordinator both live on the main actor.
///
/// No app types cross the seam: the coordinator parses params and builds the
/// wire payloads; the conformance runs the irreducibly app-coupled work
/// (workspace/panel resolution, WKWebView JavaScript, cookie stores, panel
/// actions) and returns Sendable snapshots / resolution enums. Multi-step
/// commands (state save/load, cookies) run inside ONE seam call because the
/// legacy waits pump the run loop — the panel must be captured once, exactly
/// as the legacy `v2BrowserWithPanel` closure did.
@MainActor
public protocol ControlBrowserContext: AnyObject {
    // MARK: - open_split / availability / diff viewer

    /// Whether the cmux browser is disabled
    /// (`BrowserAvailabilitySettings.isDisabled()`), for `browser.open_split`.
    func controlBrowserIsAvailabilityDisabled() -> Bool

    /// Whether the cmux browser is enabled
    /// (`BrowserAvailabilitySettings.isEnabled()`), for `browser.tab.new`.
    func controlBrowserIsAvailabilityEnabled() -> Bool

    /// Whether the raw `url` param parses to a diff-viewer URL (the legacy
    /// `v2IsDiffViewerURL` over the parsed URL; `nil`/unparseable → `false`).
    ///
    /// - Parameter urlString: The raw `url` param, if any.
    /// - Returns: Whether it is a diff-viewer URL.
    func controlBrowserIsDiffViewerURL(_ urlString: String?) -> Bool

    /// The browser-disabled external-open fallback shared by
    /// `browser.open_split` and `browser.tab.new` (the legacy
    /// `v2BrowserDisabledExternalOpenResult`), reusing the surface domain's
    /// outcome type.
    ///
    /// - Parameters:
    ///   - rawURL: The raw `url` param, if any.
    ///   - routing: The routing selectors (for the window id in the payload).
    /// - Returns: The outcome.
    func controlBrowserDisabledExternalOpen(
        rawURL: String?,
        routing: ControlRoutingSelectors
    ) -> ControlSurfaceBrowserDisabledOutcome

    /// Registers the trusted diff-viewer allowlist when the URL is a
    /// diff-viewer URL (the legacy `v2RegisterDiffViewerURLIfNeeded`).
    ///
    /// - Parameters:
    ///   - urlString: The raw `url` param, if any.
    ///   - token: The `diff_viewer_token` param, if any.
    ///   - files: The raw `diff_viewer_files` param, if any.
    /// - Returns: The registration outcome.
    func controlBrowserRegisterDiffViewer(
        urlString: String?,
        token: String?,
        files: JSONValue?
    ) -> ControlBrowserDiffViewerRegistration

    /// Performs the `browser.open_split` main step (external-open rules,
    /// window/workspace focusing, split or sibling placement).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - inputs: The pre-parsed inputs.
    /// - Returns: The open-split resolution.
    func controlBrowserOpenSplit(
        routing: ControlRoutingSelectors,
        inputs: ControlBrowserOpenSplitInputs
    ) -> ControlBrowserOpenSplitResolution

    // MARK: - navigate / history nav

    /// Navigates a browser surface for `browser.navigate` (`navigateSmart`).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The target surface.
    ///   - urlString: The `url` param.
    /// - Returns: The nav resolution.
    func controlBrowserNavigate(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        urlString: String
    ) -> ControlBrowserNavResolution

    /// Runs a history action for `browser.back`/`forward`/`reload`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The target surface.
    ///   - action: The validated action.
    /// - Returns: The nav resolution.
    func controlBrowserNavAction(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        action: ControlBrowserNavAction
    ) -> ControlBrowserNavResolution

    // MARK: - focused-browser actions

    /// Toggles React Grab for `browser.react_grab.toggle`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - browserSurfaceID: The explicit `surface_id`, if any.
    ///   - returnSurfaceID: The explicit `return_to`, if any.
    /// - Returns: The toggle resolution.
    func controlBrowserReactGrabToggle(
        routing: ControlRoutingSelectors,
        browserSurfaceID: UUID?,
        returnSurfaceID: UUID?
    ) -> ControlBrowserReactGrabResolution

    /// Toggles developer tools for `browser.devtools.toggle`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - target: The focused-action target.
    /// - Returns: The handled resolution.
    func controlBrowserDevToolsToggle(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget
    ) -> ControlBrowserHandledResolution

    /// Shows the developer-tools console for `browser.console.show`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - target: The focused-action target.
    /// - Returns: The handled resolution.
    func controlBrowserConsoleShow(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget
    ) -> ControlBrowserHandledResolution

    /// Sets browser focus mode for `browser.focus_mode.set` (focusing the
    /// target panel first when activating, as the legacy body did).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - target: The focused-action target.
    ///   - action: The validated mode action.
    /// - Returns: The handled resolution.
    func controlBrowserFocusModeSet(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        action: ControlBrowserFocusModeAction
    ) -> ControlBrowserHandledResolution

    /// Adjusts zoom for `browser.zoom.set`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - target: The focused-action target.
    ///   - direction: The validated direction.
    /// - Returns: The handled resolution.
    func controlBrowserZoomSet(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        direction: ControlBrowserZoomDirection
    ) -> ControlBrowserHandledResolution

    // MARK: - history / url / web view focus

    /// Clears the default profile's browser history for
    /// `browser.history.clear` (`BrowserHistoryStore.shared.clearHistory()`).
    func controlBrowserClearDefaultProfileHistory()

    /// Reads a browser surface's current URL for `browser.url.get`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The target surface.
    /// - Returns: The URL resolution.
    func controlBrowserCurrentURL(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserURLResolution

    /// Moves first responder into the web view for `browser.focus_webview`
    /// (window/workspace activation + omnibar autofocus suppression first, as
    /// the legacy body did).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The target surface.
    /// - Returns: The focus resolution.
    func controlBrowserFocusWebView(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserFocusWebViewResolution

    /// Whether first responder is inside the web view for
    /// `browser.is_webview_focused` (`false` when the surface/panel/window
    /// does not resolve, as the legacy body did).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - surfaceID: The target surface.
    /// - Returns: Whether the web view is focused.
    func controlBrowserIsWebViewFocused(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> Bool

    // MARK: - script execution / element refs

    /// Resolves the target browser surface and runs a coordinator-built
    /// script, returning the normalized outcome. Backs `browser.snapshot`,
    /// `browser.storage.*`, `browser.console.list/clear`, and
    /// `browser.errors.list`.
    ///
    /// - Parameters:
    ///   - target: The browser surface target.
    ///   - script: The script source.
    ///   - timeout: The legacy timeout in seconds.
    ///   - mode: Which legacy execution primitive to use.
    /// - Returns: The script resolution.
    func controlBrowserRunScript(
        target: ControlBrowserSurfaceTarget,
        script: String,
        timeout: Double,
        mode: ControlBrowserScriptMode
    ) -> ControlBrowserScriptResolution

    // MARK: - cookies

    /// Reads all cookies from the resolved panel's store for
    /// `browser.cookies.get` (the coordinator filters and serializes).
    ///
    /// - Parameter target: The browser surface target.
    /// - Returns: The cookies resolution.
    func controlBrowserCookiesGet(
        target: ControlBrowserSurfaceTarget
    ) -> ControlBrowserCookiesGetResolution

    /// Writes cookie rows to the resolved panel's store for
    /// `browser.cookies.set`, in row order, stopping at the first invalid row
    /// or timeout (legacy behavior).
    ///
    /// - Parameters:
    ///   - target: The browser surface target.
    ///   - rows: The coordinator-built cookie rows (JSON objects).
    /// - Returns: The set resolution.
    func controlBrowserCookiesSet(
        target: ControlBrowserSurfaceTarget,
        rows: [JSONValue]
    ) -> ControlBrowserCookiesSetResolution

    /// Deletes matching cookies from the resolved panel's store for
    /// `browser.cookies.clear`.
    ///
    /// - Parameters:
    ///   - target: The browser surface target.
    ///   - name: The `name` filter, if any.
    ///   - domain: The `domain` filter, if any.
    ///   - hasAllParam: Whether an `all` param was present (affects the legacy
    ///     clear-all default).
    /// - Returns: The clear resolution.
    func controlBrowserCookiesClear(
        target: ControlBrowserSurfaceTarget,
        name: String?,
        domain: String?,
        hasAllParam: Bool
    ) -> ControlBrowserCookiesClearResolution

    // MARK: - state save / load

    /// Captures URL + cookies + storage + frame selector in one resolved-panel
    /// pass for `browser.state.save` (the coordinator writes the file).
    ///
    /// - Parameters:
    ///   - target: The browser surface target.
    ///   - storageScript: The coordinator-built storage readout script.
    /// - Returns: The capture resolution.
    func controlBrowserStateCapture(
        target: ControlBrowserSurfaceTarget,
        storageScript: String
    ) -> ControlBrowserStateCaptureResolution

    /// Applies a loaded state file in one resolved-panel pass for
    /// `browser.state.load`: frame selector, then navigation, then cookies,
    /// then the storage script (the legacy order, best-effort as legacy).
    ///
    /// - Parameters:
    ///   - target: The browser surface target.
    ///   - frameSelector: The non-empty `frame_selector`, or `nil` to clear.
    ///   - navigateToURLString: The non-empty `url` to navigate to, if any
    ///     (the app parses it; unparseable URLs are skipped, as legacy).
    ///   - cookieRows: The raw cookie rows from the state file.
    ///   - storageScript: The coordinator-built storage apply script, if the
    ///     file carried a storage object.
    /// - Returns: The apply resolution.
    func controlBrowserStateApply(
        target: ControlBrowserSurfaceTarget,
        frameSelector: String?,
        navigateToURLString: String?,
        cookieRows: [JSONValue],
        storageScript: String?
    ) -> ControlBrowserStateApplyResolution

    // MARK: - tabs

    /// Snapshots the workspace's browser tabs for `browser.tab.list`.
    ///
    /// - Parameter routing: The routing selectors.
    /// - Returns: The snapshot, or `nil` when no workspace resolves.
    func controlBrowserTabList(routing: ControlRoutingSelectors) -> ControlBrowserTabListSnapshot?

    /// Creates a browser tab for `browser.tab.new`, walking the legacy pane
    /// fallback ladder.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - urlString: The raw `url` param, if any (the app parses it).
    ///   - explicitPaneID: `pane_id` or `target_pane_id`, if any.
    ///   - paneFromSurfaceID: The `surface_id` whose pane is the fallback
    ///     target, if any.
    /// - Returns: The creation resolution.
    func controlBrowserTabNew(
        routing: ControlRoutingSelectors,
        urlString: String?,
        explicitPaneID: UUID?,
        paneFromSurfaceID: UUID?
    ) -> ControlBrowserTabNewResolution

    /// Focuses a browser tab for `browser.tab.switch`, walking the legacy
    /// explicit-id / index / `surface_id` ladder.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - explicitID: `target_surface_id` or `tab_id`, if any.
    ///   - index: The `index` param, if any.
    ///   - surfaceID: The `surface_id` param, if any.
    /// - Returns: The switch resolution.
    func controlBrowserTabSwitch(
        routing: ControlRoutingSelectors,
        explicitID: UUID?,
        index: Int?,
        surfaceID: UUID?
    ) -> ControlBrowserTabSwitchResolution

    /// Closes a browser tab for `browser.tab.close`, walking the legacy
    /// explicit-id / index / `surface_id` / focused ladder.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors.
    ///   - explicitID: `target_surface_id` or `tab_id`, if any.
    ///   - index: The `index` param, if any.
    ///   - surfaceID: The `surface_id` param, if any.
    /// - Returns: The close resolution.
    func controlBrowserTabClose(
        routing: ControlRoutingSelectors,
        explicitID: UUID?,
        index: Int?,
        surfaceID: UUID?
    ) -> ControlBrowserTabCloseResolution

    // MARK: - unsupported-network bookkeeping

    /// Records a `browser.network.route`/`unroute` attempt in the per-surface
    /// unsupported-request log (the legacy `v2BrowserRecordUnsupportedRequest`,
    /// bounded to 256 entries; the log lives app-side so the surface-close
    /// cleanup keeps working).
    ///
    /// - Parameters:
    ///   - surfaceID: The surface the attempt targeted.
    ///   - request: The recorded request object.
    func controlBrowserRecordUnsupportedRequest(surfaceID: UUID, request: JSONValue)

    /// The recorded unsupported-request log for `browser.network.requests`.
    ///
    /// - Parameter surfaceID: The surface to read.
    /// - Returns: The recorded request objects, oldest first.
    func controlBrowserUnsupportedRequests(surfaceID: UUID) -> [JSONValue]

    // MARK: - import dialog

    /// Resolves the `destination_profile` query against the app's browser
    /// profiles for `browser.import.dialog` (UUID, then display name/slug,
    /// then optional creation — the legacy ladder).
    ///
    /// - Parameters:
    ///   - query: The non-empty query.
    ///   - createIfMissing: Whether `create_destination_profile`/
    ///     `create_profile` was true.
    /// - Returns: The profile resolution.
    func controlBrowserImportResolveDestinationProfile(
        query: String,
        createIfMissing: Bool
    ) -> ControlBrowserImportProfileResolution

    /// Schedules presentation of the browser data import dialog for
    /// `browser.import.dialog` (the legacy `Task { @MainActor … }` hop).
    ///
    /// - Parameters:
    ///   - scope: The validated scope, if any.
    ///   - destinationProfileID: The resolved destination profile, if any.
    func controlBrowserImportPresentDialog(
        scope: ControlBrowserImportScope?,
        destinationProfileID: UUID?
    )
}
