package import WebKit

/// A script in a WebKit page without a user gesture (`BrowserScriptGesture.cmux`). Every public
/// WKWebView evaluation (`evaluateJavaScript`, `callAsyncJavaScript`) runs with a forced user
/// gesture, which gives the page the person's activation, in any content world (activation belongs
/// to the document). WebKit's SPI takes the gesture as a flag:
/// - `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:`
///   (any content world), else for the page world the older
///   `_evaluateJavaScriptWithoutUserGesture:completionHandler:`;
/// - `_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:` for a
///   function body with arguments.
/// Where none answers the call throws `BrowserTabError.unsupported` rather than run with a gesture
/// (a probe then counts as unanswered, and the page stays awake: the safe side). Which macOS majors
/// have each is checked by an exec probe on the fleet (macOS 14, 15, 26, 27).
@MainActor
package struct WebKitGestureFreeEvaluation {
    let webView: WKWebView

    package init(webView: WKWebView) {
        self.webView = webView
    }

    // crash-allow: a string selector traps only when sent unanswered; responds(to:) gates every send below, and a WebKit without the SPI throws .unsupported.
    private static let evaluateInWorld = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")
    // crash-allow: as above (responds(to:) gates the send).
    private static let evaluateInPageWorld = NSSelectorFromString("_evaluateJavaScriptWithoutUserGesture:completionHandler:")
    // crash-allow: as above (responds(to:) gates the send).
    private static let callAsyncInWorld = NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")

    private typealias Completion = @convention(block) (Any?, (any Error)?) -> Void
    private typealias EvaluateInWorld = @convention(c) (AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool, @escaping Completion) -> Void
    private typealias EvaluateInPageWorld = @convention(c) (AnyObject, Selector, NSString, @escaping Completion) -> Void
    private typealias CallAsyncInWorld = @convention(c) (AnyObject, Selector, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Bool, @escaping Completion) -> Void

    /// The script's completion value (main frame), as `WebKitTab.evaluate` returns it.
    package func evaluate(_ script: String, in world: WKContentWorld) async throws -> BrowserJSValue {
        if webView.responds(to: Self.evaluateInWorld) {
            let send = unsafeBitCast(webView.method(for: Self.evaluateInWorld), to: EvaluateInWorld.self)
            return try await answer { send(webView, Self.evaluateInWorld, script as NSString, nil, nil, world, false, $0) }
        }
        if world == .page, webView.responds(to: Self.evaluateInPageWorld) {
            let send = unsafeBitCast(webView.method(for: Self.evaluateInPageWorld), to: EvaluateInPageWorld.self)
            return try await answer { send(webView, Self.evaluateInPageWorld, script as NSString, $0) }
        }
        throw BrowserTabError.unsupported("evaluation without a user gesture")
    }

    /// `body` run as an async function with named `arguments` (main frame), what it resolves to.
    func callAsync(_ body: String, arguments: [String: Any], in world: WKContentWorld) async throws -> BrowserJSValue {
        guard webView.responds(to: Self.callAsyncInWorld) else { throw BrowserTabError.unsupported("a function call without a user gesture") }
        let send = unsafeBitCast(webView.method(for: Self.callAsyncInWorld), to: CallAsyncInWorld.self)
        return try await answer { send(webView, Self.callAsyncInWorld, body as NSString, arguments as NSDictionary, nil, world, false, $0) }
    }

    /// Fire and forget: a script whose answer nobody reads (a clear, an exit); an engine without a
    /// gesture-free path runs nothing.
    func run(_ script: String, in world: WKContentWorld) {
        Task { _ = try? await evaluate(script, in: world) }
    }

    private func answer(_ send: (@escaping Completion) -> Void) async throws -> BrowserJSValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserJSValue, any Error>) in
            send { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: BrowserJSValue(foundation: value)) }
            }
        }
    }
}
