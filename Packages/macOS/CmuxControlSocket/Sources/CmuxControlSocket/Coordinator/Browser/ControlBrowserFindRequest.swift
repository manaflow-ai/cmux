/// The parsed, validated input for one `browser.find.*` element locator, handed
/// from ``ControlBrowserQueryWorker`` to the ``ControlBrowserQueryReading`` seam.
///
/// The worker owns the param parsing and the missing-param `invalid_params`
/// branches; this value carries exactly the inputs the legacy `v2BrowserFind*`
/// bodies passed into the finder-script builders. The seam (app side) selects
/// the finder body via the package-resident `BrowserControlService` builders,
/// resolves the browser panel, runs the JavaScript on the socket-worker lane,
/// decodes the result, and allocates the element ref.
///
/// `params` is carried verbatim because the panel-resolution head
/// (`v2BrowserWithPanelContext`) reads `surface_id`/`tab_id`/`pane_id` from it
/// with a precedence that terminal-style routing selectors cannot express.
public enum ControlBrowserFindRequest: Sendable {
    /// `browser.find.role` — `role`/`name` already lowercased, `exact` parsed.
    case role(params: [String: JSONValue], role: String, name: String?, exact: Bool)
    /// `browser.find.text` — `text` already lowercased, `exact` parsed.
    case text(params: [String: JSONValue], text: String, exact: Bool)
    /// `browser.find.label` — `label` already lowercased, `exact` parsed.
    case label(params: [String: JSONValue], label: String, exact: Bool)
    /// `browser.find.placeholder` — `placeholder` already lowercased.
    case placeholder(params: [String: JSONValue], placeholder: String, exact: Bool)
    /// `browser.find.alt` — `alt` already lowercased.
    case alt(params: [String: JSONValue], alt: String, exact: Bool)
    /// `browser.find.title` — `title` already lowercased.
    case title(params: [String: JSONValue], title: String, exact: Bool)
    /// `browser.find.testid` — `testid` raw (not lowercased; the legacy body did
    /// not fold case for test ids).
    case testID(params: [String: JSONValue], testID: String)
    /// `browser.find.first` — resolves `selector` (a CSS selector or `@eN` ref)
    /// then matches the first node.
    case first(params: [String: JSONValue], rawSelector: String)
    /// `browser.find.last` — resolves `selector` then matches the last node.
    case last(params: [String: JSONValue], rawSelector: String)
    /// `browser.find.nth` — resolves `selector` then matches node `index`.
    case nth(params: [String: JSONValue], rawSelector: String, index: Int)
}
