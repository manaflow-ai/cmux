import Foundation

/// A seam that evaluates find-in-page JavaScript against the page hosting the find session.
///
/// The app target conforms a thin adapter over the panel's `WKWebView` to this protocol so the
/// find service never reaches the web view, the window, or any panel state directly. WebKit's
/// `evaluateJavaScript` is main-thread only, so the seam is `@MainActor`.
@MainActor
public protocol BrowserFindScriptEvaluating: AnyObject {
    /// Evaluates a find-in-page script in the page and returns the raw result value.
    ///
    /// Conformers forward to the underlying web view's `evaluateJavaScript`. The returned value
    /// is the JS evaluation result (a JSON string for search/next/previous, `"ok"` for clear),
    /// parsed by ``BrowserFindMatchCount/parse(_:)``.
    /// - Parameter script: The script to run.
    /// - Returns: The raw evaluation result, or `nil` when the script produces no value.
    /// - Throws: Any error WebKit raises while evaluating the script.
    func evaluate(_ script: BrowserFindScript) async throws -> Any?
}
