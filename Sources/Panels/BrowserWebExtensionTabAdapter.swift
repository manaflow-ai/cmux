import AppKit
import WebKit

/// Presents one `BrowserPanel` to web extensions as a browser tab.
///
/// All `WKWebExtensionTab` requirements are optional; this implements the subset
/// extensions like Bitwarden need to identify, read, and navigate the active tab.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    private(set) weak var panel: BrowserPanel?
    private weak var support: BrowserWebExtensionSupport?
    private let panelID: UUID

    init(panel: BrowserPanel, support: BrowserWebExtensionSupport) {
        self.panel = panel
        self.support = support
        self.panelID = panel.id
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        support?.windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        support?.indexInWindow(of: panelID) ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        panel?.webView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        panel?.webView.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        panel?.webView.title
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let webView = panel?.webView else { return true }
        return !webView.isLoading
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        support?.activePanelID == panelID
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        support?.noteActivated(panelID: panelID)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin {
            panel?.webView.reloadFromOrigin()
        } else {
            panel?.webView.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel?.webView.goForward()
        completionHandler(nil)
    }
}
