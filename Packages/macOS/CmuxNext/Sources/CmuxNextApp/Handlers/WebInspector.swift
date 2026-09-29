import AppKit
import CmuxNextBrowser
import WebKit

/// Developer tools for a page. WebKit's inspector (`_WKInspector`) supports
/// toggling and the console view; other engines only open their DevTools.
enum WebInspector {
    static func toggle(_ tab: any BrowserTab) {
        guard let inspector = inspector(of: tab) else { return tab.showDevTools() }
        let isVisible = inspector.responds(to: Selector(("isVisible"))) && (inspector.value(forKey: "visible") as? Bool ?? false)
        let selector = isVisible ? Selector(("close")) : Selector(("show"))
        if inspector.responds(to: selector) { inspector.perform(selector) }
    }

    static func showConsole(_ tab: any BrowserTab) {
        guard let inspector = inspector(of: tab), inspector.responds(to: Selector(("showConsole"))) else {
            return tab.showDevTools()
        }
        inspector.perform(Selector(("showConsole")))
    }

    private static func inspector(of tab: any BrowserTab) -> NSObject? {
        guard let webView = (tab as? WebKitTab)?.webView, webView.responds(to: Selector(("_inspector"))) else { return nil }
        return webView.perform(Selector(("_inspector")))?.takeUnretainedValue() as? NSObject
    }
}
