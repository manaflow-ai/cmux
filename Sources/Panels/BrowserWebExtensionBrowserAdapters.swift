import WebKit

@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    weak var windowAdapter: BrowserWebExtensionWindowAdapter?

    init(panel: BrowserPanel, windowAdapter: BrowserWebExtensionWindowAdapter) {
        self.panel = panel
        self.windowAdapter = windowAdapter
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let panel else { return NSNotFound }
        return windowAdapter?.tabAdapters.firstIndex { $0.panel === panel } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let panel, panel.internalPage == nil else { return nil }
        return panel.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        panel?.displayTitle
    }
}

@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var workspace: Workspace?
    var tabAdapters: [BrowserWebExtensionTabAdapter] = []

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        compactTabs().map { $0 as any WKWebExtensionTab }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let workspace else { return nil }
        let focusedPanelID = workspace.focusedPanelId
        return compactTabs().first { $0.panel?.id == focusedPanelID }
            ?? compactTabs().first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = compactTabs().first?.panel?.webView.window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func focus(for context: WKWebExtensionContext) async throws {
        guard let workspace,
              let panelID = activeTab(for: context).flatMap({ ($0 as? BrowserWebExtensionTabAdapter)?.panel?.id }) else {
            return
        }
        workspace.focusPanel(panelID)
    }

    func compactTabs() -> [BrowserWebExtensionTabAdapter] {
        tabAdapters.removeAll { $0.panel == nil }
        return tabAdapters.filter { $0.panel?.internalPage == nil }
    }
}
