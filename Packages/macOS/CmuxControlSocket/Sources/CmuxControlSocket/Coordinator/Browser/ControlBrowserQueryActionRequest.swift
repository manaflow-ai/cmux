/// The parsed, validated input for one read-only `browser.get.*` / `browser.is.*`
/// query command, handed from ``ControlBrowserQueryWorker`` to the
/// ``ControlBrowserQueryReading`` seam.
///
/// These are the stateless JS-eval reads: each command resolves the browser
/// panel, runs a read-only `document.querySelector`-based script on the
/// socket-worker lane, and shapes the result. The worker owns the leaf-param
/// parsing and the only missing-param `invalid_params` branch in this family
/// (`attr`/`name` for `browser.get.attr`); this value carries exactly the inputs
/// the legacy `v2BrowserGetText` / `v2BrowserGetHTML` / … bodies passed into the
/// app-side resolver.
///
/// The app conformer selects the per-action read script, runs the shared
/// `v2BrowserSelectorAction` retry loop (still shared with the `browser.*`
/// interaction commands and so kept app-side) for the selector-action getters, or
/// the `v2BrowserWithPanelContext` `querySelectorAll` body for `get.count`, and
/// returns the already-shaped wire result.
///
/// `browser.get.title` is deliberately NOT a member: it reads the browser panel's
/// `pageTitle` synchronously on the main actor (no page JavaScript), so it runs on
/// the main-actor dispatch lane (not the worker lane the execution policy assigns
/// these JS-eval getters) and stays on that path, exactly as on the base.
///
/// `params` is carried verbatim because the panel-resolution head reads
/// `surface_id`/`tab_id`/`pane_id` from it with a precedence that terminal-style
/// routing selectors cannot express, and the shared retry body re-reads
/// `selector`/`retry_attempts`/`snapshot_after`/… from it.
public enum ControlBrowserQueryActionRequest: Sendable {
    /// `browser.get.text` — `v2BrowserGetText`, via the shared
    /// `v2BrowserSelectorAction` with the `innerText`/`textContent` read script.
    case getText(params: [String: JSONValue])
    /// `browser.get.html` — `v2BrowserGetHTML`, via the `outerHTML` read script.
    case getHTML(params: [String: JSONValue])
    /// `browser.get.value` — `v2BrowserGetValue`, via the `value`/`textContent`
    /// read script.
    case getValue(params: [String: JSONValue])
    /// `browser.get.attr` — `v2BrowserGetAttr`. `attr` is the validated (trimmed,
    /// non-empty) `attr` or `name` leaf the legacy body required before resolving
    /// the panel.
    case getAttr(params: [String: JSONValue], attr: String)
    /// `browser.get.count` — `v2BrowserGetCount`. Reads
    /// `document.querySelectorAll(selector).length` via `v2BrowserWithPanelContext`
    /// (not the shared selector-action retry loop).
    case getCount(params: [String: JSONValue])
    /// `browser.get.box` — `v2BrowserGetBox`, via the `getBoundingClientRect` read
    /// script.
    case getBox(params: [String: JSONValue])
    /// `browser.get.styles` — `v2BrowserGetStyles`, via the `getComputedStyle` read
    /// script (single property when `property` is present, else the curated set).
    case getStyles(params: [String: JSONValue])
    /// `browser.is.visible` — `v2BrowserIsVisible`, via the display/visibility/
    /// opacity/rect read script.
    case isVisible(params: [String: JSONValue])
    /// `browser.is.enabled` — `v2BrowserIsEnabled`, via the `!el.disabled` read
    /// script.
    case isEnabled(params: [String: JSONValue])
    /// `browser.is.checked` — `v2BrowserIsChecked`, via the `el.checked` read
    /// script.
    case isChecked(params: [String: JSONValue])
}
