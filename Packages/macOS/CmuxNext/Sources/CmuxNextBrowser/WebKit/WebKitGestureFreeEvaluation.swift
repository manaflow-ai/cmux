import WebKit

/// A script in a WebKit page without a user gesture (`BrowserScriptGesture.cmux`). Every public
/// WKWebView evaluation (`evaluateJavaScript`, `callAsyncJavaScript`) runs with a forced user
/// gesture, which gives the page the person's activation. WebKit's
/// `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:`
/// (macOS 14 and later) takes the gesture as a flag; where it is missing the call throws
/// `BrowserTabError.unsupported` rather than run with a gesture (a probe then counts as
/// unanswered, and the page stays awake: the safe side).
@MainActor
struct WebKitGestureFreeEvaluation {
    let webView: WKWebView

    // crash-allow: a string selector traps only when sent unanswered; responds(to:) in `evaluate` gates the send, and a WebKit without the SPI throws .unsupported.
    private static let selector = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")
    private typealias Evaluate = @convention(c) (
        AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool, @escaping @convention(block) (Any?, (any Error)?) -> Void
    ) -> Void

    /// The script's completion value (main frame), as `WebKitTab.evaluate` returns it.
    func evaluate(_ script: String, in world: WKContentWorld) async throws -> BrowserJSValue {
        guard webView.responds(to: Self.selector) else { throw BrowserTabError.unsupported("evaluation without a user gesture") }
        let evaluate = unsafeBitCast(webView.method(for: Self.selector), to: Evaluate.self)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserJSValue, any Error>) in
            evaluate(webView, Self.selector, script as NSString, nil, nil, world, false) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: BrowserJSValue(foundation: value)) }
            }
        }
    }
}
