import Foundation
import WebKit

/// An agent's marks on a WebKit page, as on Chromium (CEFTab+PasswordFill): its visits name the agent
/// and its session in history (BrowserPageLoads), and none of them colours a link as visited (RFD 0125 D5:
/// agent visits never feed visited-link colour). The mark is the tab's for the rest of its life.
extension WebKitTab {
    public func markAgentDriven() {
        guard !isAgentDriven else { return }
        isAgentDriven = true
        WebKitVisitedLinks.stopAdding(webView)
    }

    public func noteAgentSession(_ session: String) { agentSessionID = session }
}

/// WebKit adds each standard load's URL to the page's visited-link store, which colours `:visited`
/// links. The private `_addsVisitedLinks` (WKWebViewPrivate.h) turns that off for one web view; a WebKit
/// without it keeps adding, as before. Its accessors are called by selector: KVC on the key
/// `_addsVisitedLinks` looks for `set_addsVisitedLinks:`, not `_setAddsVisitedLinks:`, and raises
/// NSUnknownKeyException (#64709 did, and an agent's mark ended the app).
enum WebKitVisitedLinks {
    // crash-allow: making a selector from a string never raises; every use is behind responds(to:) on it.
    static let setter = NSSelectorFromString("_setAddsVisitedLinks:")
    // crash-allow: making a selector from a string never raises; every use is behind responds(to:) on it.
    static let getter = NSSelectorFromString("_addsVisitedLinks")

    static func stopAdding(_ webView: WKWebView) {
        guard webView.responds(to: setter), let method = webView.method(for: setter) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Set.self)(webView, setter, false)
    }

    /// Whether `webView` adds its loads as visited links (nil: this WebKit has no switch).
    static func adds(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: getter), let method = webView.method(for: getter) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Get.self)(webView, getter)
    }
}
