import Foundation

/// Injected seam that runs an omnibar page-focus JavaScript snippet inside the
/// browser panel's live web content and delivers the raw evaluation result.
///
/// The concrete conformer lives in the app target and forwards to the panel's
/// `WKWebView.evaluateJavaScript(_:completionHandler:)`. Inverting the web-view
/// reach behind this protocol keeps `BrowserOmnibarPageFocusRepository` free of
/// any WebKit or `BrowserPanel` dependency and lets tests drive capture/restore
/// with a fake evaluator. The conformer must hold its owner weakly to avoid a
/// retain cycle with the repository it ultimately backs.
@MainActor
public protocol BrowserOmnibarScriptEvaluating: AnyObject {
    /// Evaluates `script` in the page and reports the WebKit result tuple.
    ///
    /// The completion is invoked on the main actor exactly once. When the
    /// underlying web view is gone the conformer reports `(nil, nil)` so the
    /// repository treats it as a non-restorable outcome rather than crashing.
    ///
    /// - Parameters:
    ///   - script: The self-invoking JavaScript expression to evaluate.
    ///   - completion: Receives the JavaScript value (typically a `String`
    ///     status code) and any evaluation error, mirroring WebKit's API.
    func evaluateOmnibarPageFocusScript(
        _ script: String,
        completion: @escaping @MainActor (Any?, (any Error)?) -> Void
    )
}
