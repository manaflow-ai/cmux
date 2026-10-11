import AppKit
import WebKit

/// File > Print… of a page (`browserPrint`). WebKit prints its view through
/// the system print panel, a sheet on the tab's window; Chromium opens its
/// print preview over the page (`cmux_shim_print`), as the page's own
/// window.print() does.
public struct BrowserPagePrint {
    let tab: any BrowserTab

    public init(_ tab: any BrowserTab) {
        self.tab = tab
    }

    /// False when the tab cannot print now (another engine, no page, the
    /// page is in no window, or its window already shows a sheet).
    public func run() -> Bool {
        switch tab {
        case let tab as WebKitTab: printWebKit(tab.webView)
        case let tab as CEFTab: tab.browserID.map { tab.runtime.shim?.printPage($0) == 1 } ?? false
        default: false
        }
    }

    private func printWebKit(_ webView: WKWebView) -> Bool {
        guard let window = webView.window, window.attachedSheet == nil else { return false }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // WebKit's print view has no size of its own; without one the panel
        // previews and prints blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        return true
    }
}
