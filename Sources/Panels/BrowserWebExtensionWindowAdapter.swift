import AppKit
import WebKit

/// Presents cmux's browser panels to web extensions as a single browser window.
///
/// cmux has no traditional tab strip — browser panels live in panes across
/// workspaces — so all live panels are exposed as tabs of one focused window,
/// which is the topology extensions like Bitwarden expect for
/// `tabs.query({active: true, currentWindow: true})`.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private weak var support: BrowserWebExtensionSupport?

    init(support: BrowserWebExtensionSupport) {
        self.support = support
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        support?.orderedTabAdapters ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        support?.activeTabAdapter
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    private var hostWindow: NSWindow? {
        support?.activeTabAdapter?.panel?.webView.window ?? NSApp.keyWindow
    }
}
