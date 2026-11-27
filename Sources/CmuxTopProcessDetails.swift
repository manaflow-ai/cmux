import ObjectiveC.runtime
import WebKit

enum CmuxWebContentProcessIdentifier {
    @MainActor
    static func pid(for webView: WKWebView) -> Int? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return nil
        }

        typealias WebProcessIdentifierFn = @convention(c) (AnyObject, Selector) -> Int32
        let implementation = method_getImplementation(method)
        let pid = unsafeBitCast(implementation, to: WebProcessIdentifierFn.self)(webView, selector)
        return pid > 0 ? Int(pid) : nil
    }
}
