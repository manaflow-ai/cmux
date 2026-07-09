/// The parsed, validated input for one `browser.*` interaction command, handed
/// from ``ControlBrowserInteractionWorker`` to the
/// ``ControlBrowserInteractionReading`` seam.
///
/// The worker owns the leaf-param parsing and the missing-param `invalid_params`
/// branches (`text` for `type`, `text`/`value` for `fill`, `value`/`text` for
/// `select`, `key` for `press`/`keydown`/`keyup`); this value carries exactly the
/// inputs the legacy `v2BrowserClick` / `v2BrowserType` / … bodies passed into the
/// app-side resolver. The seam (app side) resolves the browser panel, selects the
/// `BrowserControlService` script builder for the action, runs the shared
/// `v2BrowserSelectorAction` retry loop (still shared with the not-yet-extracted
/// `browser.get.*` / `browser.is.*` query commands) or the per-key/scroll panel
/// body, and runs the JavaScript on the socket-worker lane.
///
/// `params` is carried verbatim because the panel-resolution head
/// (`v2BrowserWithPanelContext`) reads `surface_id`/`tab_id`/`pane_id` from it
/// with a precedence that terminal-style routing selectors cannot express, and
/// the shared retry body re-reads `selector`/`retry_attempts`/`snapshot_after`/…
/// from it.
public enum ControlBrowserInteractionRequest: Sendable {
    /// `browser.click` — `v2BrowserClick`, via the shared `v2BrowserSelectorAction`
    /// with the `click` script builder.
    case click(params: [String: JSONValue])
    /// `browser.dblclick` — `v2BrowserDblClick`.
    case doubleClick(params: [String: JSONValue])
    /// `browser.hover` — `v2BrowserHover`.
    case hover(params: [String: JSONValue])
    /// `browser.focus` — `v2BrowserFocusElement`.
    case focusElement(params: [String: JSONValue])
    /// `browser.type` — `v2BrowserType`. `text` is the validated (trimmed,
    /// non-empty) `text` leaf.
    case type(params: [String: JSONValue], text: String)
    /// `browser.fill` — `v2BrowserFill`. `text` is the raw (possibly empty) `text`
    /// or `value` leaf, so callers can clear an input.
    case fill(params: [String: JSONValue], text: String)
    /// `browser.check` / `browser.uncheck` — `v2BrowserCheck`. `checked` selects
    /// the set-checked target and the `check`/`uncheck` action name.
    case check(params: [String: JSONValue], checked: Bool)
    /// `browser.select` — `v2BrowserSelect`. `value` is the validated `value` or
    /// `text` leaf.
    case selectOption(params: [String: JSONValue], value: String)
    /// `browser.scroll_into_view` — `v2BrowserScrollIntoView`.
    case scrollIntoView(params: [String: JSONValue])
    /// `browser.highlight` — `v2BrowserHighlight`.
    case highlight(params: [String: JSONValue])
    /// `browser.press` — `v2BrowserPress`. `key` is the validated `key` leaf.
    case press(params: [String: JSONValue], key: String)
    /// `browser.keydown` — `v2BrowserKeyDown`. `key` is the validated `key` leaf.
    case keyDown(params: [String: JSONValue], key: String)
    /// `browser.keyup` — `v2BrowserKeyUp`. `key` is the validated `key` leaf.
    case keyUp(params: [String: JSONValue], key: String)
    /// `browser.scroll` — `v2BrowserScroll`. `dx`/`dy` default to `0`; the optional
    /// selector and the window-vs-element script choice are resolved app-side.
    case scroll(params: [String: JSONValue], dx: Int, dy: Int)
}
