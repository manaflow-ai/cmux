import Foundation
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
        return windowAdapter?.compactTabs().firstIndex { $0.panel === panel } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let panel, panel.internalPage == nil else { return nil }
        return panel.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        panel?.displayTitle
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        panel?.currentURLForTabDuplication
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let panel else { return true }
        return !panel.isLoading
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        panel?.isMuted ?? false
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let panel, let windowAdapter else { return false }
        return windowAdapter.activePanelID() == panel.id
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let panel, let windowAdapter else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        windowAdapter.focusPanel(panel.id)
        completionHandler(nil)
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard selected else {
            completionHandler(nil)
            return
        }
        activate(for: context, completionHandler: completionHandler)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if fromOrigin {
            panel?.hardReload()
        } else {
            panel?.reload()
        }
        completionHandler(nil)
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let panel else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        panel.navigate(to: url)
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        panel?.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        panel?.goForward()
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    let ownerID: UUID
    let activePanelID: @MainActor () -> UUID?
    let focusPriority: @MainActor () -> Int
    let focusPanel: @MainActor (UUID) -> Void
    let orderedPanelIDs: @MainActor () -> [UUID]
    let createTab: @MainActor (Int, Bool, Bool) -> BrowserPanel?
    var tabAdapters: [BrowserWebExtensionTabAdapter] = []
    var lastReportedVisiblePanelIDs: [UUID] = []

    init(
        ownerID: UUID,
        activePanelID: @escaping @MainActor () -> UUID?,
        focusPriority: @escaping @MainActor () -> Int,
        focusPanel: @escaping @MainActor (UUID) -> Void,
        orderedPanelIDs: @escaping @MainActor () -> [UUID],
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel?
    ) {
        self.ownerID = ownerID
        self.activePanelID = activePanelID
        self.focusPriority = focusPriority
        self.focusPanel = focusPanel
        self.orderedPanelIDs = orderedPanelIDs
        self.createTab = createTab
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        compactTabs().map { $0 as any WKWebExtensionTab }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        let focusedPanelID = activePanelID()
        return compactTabs().first { $0.panel?.id == focusedPanelID }
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
        guard let panelID = activeTab(for: context).flatMap({ ($0 as? BrowserWebExtensionTabAdapter)?.panel?.id }) else {
            return
        }
        focusPanel(panelID)
    }

    func compactTabs() -> [BrowserWebExtensionTabAdapter] {
        tabAdapters.removeAll { $0.panel == nil }
        let live = tabAdapters.filter { $0.panel?.internalPage == nil }
        let order = Dictionary(
            uniqueKeysWithValues: orderedPanelIDs().enumerated().map { ($0.element, $0.offset) }
        )
        let fallback = Dictionary(
            uniqueKeysWithValues: live.enumerated().compactMap { index, adapter in
                adapter.panel.map { ($0.id, index) }
            }
        )
        return live.sorted { lhs, rhs in
            guard let lhsID = lhs.panel?.id, let rhsID = rhs.panel?.id else { return false }
            let lhsRank = order[lhsID] ?? (Int.max / 2 + (fallback[lhsID] ?? 0))
            let rhsRank = order[rhsID] ?? (Int.max / 2 + (fallback[rhsID] ?? 0))
            return lhsRank < rhsRank
        }
    }
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionAdapterError: LocalizedError {
    case tabUnavailable

    var errorDescription: String? {
        String(
            localized: "browser.extensions.error.tabUnavailable",
            defaultValue: "The browser tab is no longer available."
        )
    }
}
