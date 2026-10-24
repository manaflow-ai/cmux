import Foundation
import WebKit

/// WebKit's public `evaluateJavaScript` always runs as a user gesture (`forceUserGesture`); the
/// gesture-free path is the long-standing `_evaluateJavaScriptWithoutUserGesture:completionHandler:`
/// SPI (main world, present on macOS 14 through 27). Without it the call throws, and the caller keeps
/// the page rather than run page code under a gesture.
extension WebKitTab: BrowserGesturelessScripting {
    public func evaluateWithoutUserGesture(_ script: String) async throws -> BrowserJSValue {
        guard !isClosed else { throw BrowserTabError.closed }
        // crash-allow: a string selector traps only when sent unanswered; responds(to:) below gates the send, and a WebKit without the SPI throws .unsupported.
        let selector = NSSelectorFromString("_evaluateJavaScriptWithoutUserGesture:completionHandler:")
        guard webView.responds(to: selector) else { throw BrowserTabError.unsupported("evaluate without a user gesture") }
        typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (Any?, (any Error)?) -> Void) -> Void
        let evaluate = unsafeBitCast(webView.method(for: selector), to: Evaluate.self)
        let outcome: Result<BrowserJSValue, BrowserTabError> = await withCheckedContinuation { continuation in
            evaluate(webView, selector, script as NSString) { value, error in
                continuation.resume(returning: Self.outcome(value, error))
            }
        }
        return try outcome.get()
    }

    /// The same mapping as `evaluate(_:world:)`: an unsupported result type is `null`, an exception its message.
    private nonisolated static func outcome(_ value: Any?, _ error: (any Error)?) -> Result<BrowserJSValue, BrowserTabError> {
        guard let error else { return .success(BrowserJSValue(foundation: value)) }
        let wkError = error as? WKError
        if wkError?.code == .javaScriptResultTypeIsUnsupported { return .success(.null) }
        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        return .failure(.javaScript(message))
    }
}
