import CmuxBrowser
import Foundation
import WebKit

extension BrowserPanel {
    /// The process rendering this panel's page, 0 when none is live: the
    /// main-frame renderer helper for a Chromium page (the helper started with
    /// its `--renderer-client-id`, a child of cmux), the WebContent process for
    /// a WebKit page. Crash-injection tests end exactly this process
    /// (`debug.browser.page_status` `page_pid`, `debug.browser.crashes`).
    var debugPageProcessIdentifier: Int {
        if let enginePage {
            return (enginePage as? any BrowserPageMemoryReclaiming)?.contentProcessIdentifier ?? 0
        }
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: selector) else { return 0 }
        return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? 0
    }
}
