/// A tab whose engine can run a script in the page's main world without a user gesture.
///
/// cmux's own `evaluate(_:world:)` in the page world runs as a user gesture in both engines (an
/// agent's click on a `target=_blank` link must open the tab). The hibernation probe must not: it
/// must not count as the person's activation, and page code it runs (`beforeunload` handlers) must
/// not open a popup or a dialog on cmux's behalf. `WebKitTab` and `CEFTab` conform.
@MainActor public protocol BrowserGesturelessScripting: AnyObject {
    /// Evaluates `script` in the page's main world with no user gesture and returns its completion value.
    /// - Throws: `BrowserTabError.closed`, `BrowserTabError.unsupported` when the engine has no such
    ///   path on this macOS, or the script's error.
    func evaluateWithoutUserGesture(_ script: String) async throws -> BrowserJSValue
}
