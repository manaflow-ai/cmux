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
/// links. The private `_addsVisitedLinks` (WKWebViewPrivate.h, on by default) turns that off for one
/// web view; a WebKit without it keeps adding, as before.
enum WebKitVisitedLinks {
    // crash-allow: making a selector from a string never raises; every use is behind responds(to:) on it.
    static let setter = NSSelectorFromString("_setAddsVisitedLinks:")

    static func stopAdding(_ webView: WKWebView) {
        // crash-allow: guarded by responds(to:) on the private setter the KVC key resolves to; absent on older WebKit, skipped.
        guard webView.responds(to: setter) else { return } // crash-allow: same guard
        webView.setValue(false, forKey: "_addsVisitedLinks")
    }

    /// Whether `webView` adds its loads as visited links (nil: this WebKit has no switch).
    static func adds(_ webView: WKWebView) -> Bool? {
        guard webView.responds(to: setter) else { return nil }
        // crash-allow: guarded by responds(to:) on the setter above; WebKit declares the getter with it (one @property).
        return (webView.value(forKey: "_addsVisitedLinks") as? NSNumber)?.boolValue
    }
}
