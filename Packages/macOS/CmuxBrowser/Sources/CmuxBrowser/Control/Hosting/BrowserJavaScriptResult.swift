/// The result of one WebKit JavaScript evaluation on a browser surface, the
/// package-side spelling of the app target's former nested
/// `TerminalController.V2JavaScriptResult`.
///
/// The app's `typealias V2JavaScriptResult = BrowserJavaScriptResult` keeps every
/// existing `.success(_)` / `.failure(_)` construction and pattern match
/// resolving unchanged.
///
/// Intentionally **not** `Sendable`: the `.success` payload is the raw, untyped
/// `Any?` WebKit returns, the same value the legacy enum carried across the
/// worker lane without a `Sendable` constraint.
public enum BrowserJavaScriptResult {
    /// The script evaluated successfully, carrying its raw (untyped) JS value.
    case success(Any?)
    /// The script failed, carrying a human-readable failure message.
    case failure(String)
}
