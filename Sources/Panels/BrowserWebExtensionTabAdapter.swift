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

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        panel?.isMuted ?? false
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        support?.activePanelID == panelID
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(focusOwningCmuxTab() ? nil : webExtensionTabError(code: 3))
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard selected else {
            completionHandler(nil)
            return
        }
        completionHandler(focusOwningCmuxTab() ? nil : webExtensionTabError(code: 3))
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let panel,
              let support,
              support.canOpenExtensionRequestedBrowserURL(url, for: context) else {
            completionHandler(webExtensionTabError(code: 4))
            return
        }
        panel.navigateFromWebExtension(
            to: url,
            webViewConfiguration: support.webViewConfigurationForExtensionRequestedBrowserURL(url, for: context)
        )
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

    private func focusOwningCmuxTab() -> Bool {
        guard let panel else { return false }
        return support?.focusOwningCmuxTab(panelID: panelID, workspaceId: panel.workspaceId) ?? false
    }

    private func webExtensionTabError(code: Int) -> NSError {
        NSError(domain: "cmux.webExtension.tab", code: code)
    }
}
