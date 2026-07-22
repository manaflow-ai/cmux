import AppKit
import Foundation
import WebKit

@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var panel: BrowserPanel?
    weak var windowAdapter: BrowserWebExtensionWindowAdapter?
    weak var parentAdapter: BrowserWebExtensionTabAdapter?

    init(panel: BrowserPanel, windowAdapter: BrowserWebExtensionWindowAdapter) {
        self.panel = panel
        self.windowAdapter = windowAdapter
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windowAdapter }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let panel else { return NSNotFound }
        return windowAdapter?.compactTabs().firstIndex { $0.panel === panel } ?? NSNotFound
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { parentAdapter }

    func setParentTab(
        _ parentTab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let parentTab else {
            parentAdapter = nil
            completionHandler(nil)
            return
        }
        guard let parent = parentTab as? BrowserWebExtensionTabAdapter,
              parent.windowAdapter === windowAdapter else {
            completionHandler(BrowserWebExtensionAdapterError.parentTabUnavailable)
            return
        }
        parentAdapter = parent
        completionHandler(nil)
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let panel, panel.internalPage == nil else { return nil }
        return panel.webView
    }

    func title(for context: WKWebExtensionContext) -> String? { panel?.displayTitle }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let panel else { return false }
        return windowAdapter?.isPanelPinned(panel.id) ?? false
    }

    func setPinned(
        _ pinned: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let panel, windowAdapter?.setPanelPinned(panel.id, pinned) == true else {
            completionHandler(BrowserWebExtensionAdapterError.pinMutationFailed)
            return
        }
        completionHandler(nil)
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { false }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { false }

    func setReaderModeActive(
        _ active: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(active ? BrowserWebExtensionAdapterError.readerModeUnsupported : nil)
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { panel?.isPlayingAudio ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { panel?.isMuted ?? false }

    func setMuted(
        _ muted: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard panel?.setMuted(muted) == true else {
            completionHandler(BrowserWebExtensionAdapterError.muteMutationFailed)
            return
        }
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize { panel?.webView.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(panel?.currentPageZoomFactor() ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard zoomFactor.isFinite, zoomFactor > 0, let panel else {
            completionHandler(BrowserWebExtensionAdapterError.invalidZoomFactor)
            return
        }
        _ = panel.setPageZoomFactor(CGFloat(zoomFactor))
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? { panel?.currentURLForTabDuplication }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { panel?.pendingURLForWebExtension }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(panel?.isLoading ?? false) }

    func detectWebpageLocale(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Locale?, (any Error)?) -> Void
    ) {
        guard let webView = panel?.webView else {
            completionHandler(nil, BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        webView.evaluateJavaScript("navigator.language") { value, error in
            if let error {
                completionHandler(nil, error)
            } else if let identifier = value as? String, !identifier.isEmpty {
                completionHandler(Locale(identifier: identifier), nil)
            } else {
                completionHandler(nil, BrowserWebExtensionAdapterError.localeUnavailable)
            }
        }
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping @Sendable (NSImage?, (any Error)?) -> Void
    ) {
        guard let webView = panel?.webView else {
            completionHandler(nil, BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        webView.takeSnapshot(with: configuration, completionHandler: completionHandler)
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let panel else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        panel.navigate(to: url)
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let panel else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        if fromOrigin {
            panel.hardReload()
        } else {
            _ = panel.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let panel else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        panel.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let panel else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        panel.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let panel, let windowAdapter else {
            completionHandler(BrowserWebExtensionAdapterError.tabUnavailable)
            return
        }
        windowAdapter.focusPanel(panel.id)
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let panel, let windowAdapter else { return false }
        return windowAdapter.activePanelID() == panel.id
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard selected else {
            completionHandler(BrowserWebExtensionAdapterError.multiSelectionUnsupported)
            return
        }
        activate(for: context, completionHandler: completionHandler)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard !configuration.shouldReaderModeBeActive else {
            completionHandler(nil, BrowserWebExtensionAdapterError.readerModeUnsupported)
            return
        }
        guard let panel, let windowAdapter,
              let duplicate = windowAdapter.createTab(
                configuration.index,
                configuration.shouldBeActive,
                configuration.shouldAddToSelection
              ),
              let adapter = windowAdapter.tabAdapters.first(where: { $0.panel === duplicate }) else {
            completionHandler(nil, BrowserWebExtensionAdapterError.tabCreationFailed)
            return
        }
        if let configuredParent = configuration.parentTab as? BrowserWebExtensionTabAdapter {
            guard configuredParent.windowAdapter === windowAdapter else {
                _ = windowAdapter.closePanel(duplicate.id)
                completionHandler(nil, BrowserWebExtensionAdapterError.parentTabUnavailable)
                return
            }
            adapter.parentAdapter = configuredParent
        } else {
            adapter.parentAdapter = parentAdapter
        }
        if let targetURL = configuration.url ?? panel.currentURLForTabDuplication {
            duplicate.navigate(to: targetURL)
        }
        if configuration.shouldBePinned, !windowAdapter.setPanelPinned(duplicate.id, true) {
            _ = windowAdapter.closePanel(duplicate.id)
            completionHandler(nil, BrowserWebExtensionAdapterError.pinMutationFailed)
            return
        }
        if configuration.shouldBeMuted, !duplicate.setMuted(true) {
            _ = windowAdapter.closePanel(duplicate.id)
            completionHandler(nil, BrowserWebExtensionAdapterError.muteMutationFailed)
            return
        }
        completionHandler(adapter, nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let panel, windowAdapter?.closePanel(panel.id) == true else {
            completionHandler(BrowserWebExtensionAdapterError.tabCloseFailed)
            return
        }
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
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
    let closePanel: @MainActor (UUID) -> Bool
    let isPanelPinned: @MainActor (UUID) -> Bool
    let setPanelPinned: @MainActor (UUID, Bool) -> Bool
    var tabAdapters: [BrowserWebExtensionTabAdapter] = []
    var lastReportedVisiblePanelIDs: [UUID] = []

    init(
        ownerID: UUID,
        activePanelID: @escaping @MainActor () -> UUID?,
        focusPriority: @escaping @MainActor () -> Int,
        focusPanel: @escaping @MainActor (UUID) -> Void,
        orderedPanelIDs: @escaping @MainActor () -> [UUID],
        createTab: @escaping @MainActor (Int, Bool, Bool) -> BrowserPanel?,
        closePanel: @escaping @MainActor (UUID) -> Bool,
        isPanelPinned: @escaping @MainActor (UUID) -> Bool,
        setPanelPinned: @escaping @MainActor (UUID, Bool) -> Bool
    ) {
        self.ownerID = ownerID
        self.activePanelID = activePanelID
        self.focusPriority = focusPriority
        self.focusPanel = focusPanel
        self.orderedPanelIDs = orderedPanelIDs
        self.createTab = createTab
        self.closePanel = closePanel
        self.isPanelPinned = isPanelPinned
        self.setPanelPinned = setPanelPinned
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        compactTabs().map { $0 as any WKWebExtensionTab }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        let focusedPanelID = activePanelID()
        return compactTabs().first { $0.panel?.id == focusedPanelID }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = hostWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = hostWindow else {
            completionHandler(BrowserWebExtensionAdapterError.windowUnavailable)
            return
        }
        switch state {
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            if window.isZoomed { window.performZoom(nil) }
        case .minimized:
            window.miniaturize(nil)
        case .maximized:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isZoomed { window.performZoom(nil) }
        case .fullscreen:
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        @unknown default:
            completionHandler(BrowserWebExtensionAdapterError.windowMutationUnsupported)
            return
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { hostWindow?.screen?.frame ?? .null }
    func frame(for context: WKWebExtensionContext) -> CGRect { hostWindow?.frame ?? .null }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = hostWindow else {
            completionHandler(BrowserWebExtensionAdapterError.windowUnavailable)
            return
        }
        window.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext) async throws {
        guard let panelID = activePanelID(), hostWindow != nil else {
            throw BrowserWebExtensionAdapterError.windowUnavailable
        }
        hostWindow?.makeKeyAndOrderFront(nil)
        focusPanel(panelID)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(BrowserWebExtensionAdapterError.windowMutationUnsupported)
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

    private var hostWindow: NSWindow? {
        compactTabs().compactMap { $0.panel?.webView.window }.first
    }
}

@available(macOS 15.4, *)
private enum BrowserWebExtensionAdapterError: LocalizedError {
    case tabUnavailable
    case parentTabUnavailable
    case pinMutationFailed
    case muteMutationFailed
    case readerModeUnsupported
    case invalidZoomFactor
    case localeUnavailable
    case multiSelectionUnsupported
    case tabCreationFailed
    case tabCloseFailed
    case windowUnavailable
    case windowMutationUnsupported

    var errorDescription: String? {
        switch self {
        case .tabUnavailable:
            String(localized: "browser.extensions.error.tabUnavailable", defaultValue: "The browser tab is no longer available.")
        case .parentTabUnavailable:
            String(localized: "browser.extensions.error.parentTabUnavailable", defaultValue: "The parent browser tab is unavailable.")
        case .pinMutationFailed:
            String(localized: "browser.extensions.error.pinFailed", defaultValue: "The browser tab could not be pinned.")
        case .muteMutationFailed:
            String(localized: "browser.extensions.error.muteFailed", defaultValue: "The browser tab audio setting could not be changed.")
        case .readerModeUnsupported:
            String(localized: "browser.extensions.error.readerModeUnsupported", defaultValue: "Reader mode is not supported in cmux browser tabs.")
        case .invalidZoomFactor:
            String(localized: "browser.extensions.error.invalidZoom", defaultValue: "The extension requested an invalid zoom level.")
        case .localeUnavailable:
            String(localized: "browser.extensions.error.localeUnavailable", defaultValue: "The webpage locale is unavailable.")
        case .multiSelectionUnsupported:
            String(localized: "browser.extensions.error.multiSelectionUnsupported", defaultValue: "Selecting multiple browser tabs is not supported.")
        case .tabCreationFailed:
            String(localized: "browser.extensions.error.openTabFailed", defaultValue: "The extension could not open a browser tab.")
        case .tabCloseFailed:
            String(localized: "browser.extensions.error.closeTabFailed", defaultValue: "The extension could not close the browser tab.")
        case .windowUnavailable:
            String(localized: "browser.extensions.error.windowUnavailable", defaultValue: "The browser window is unavailable.")
        case .windowMutationUnsupported:
            String(localized: "browser.extensions.error.windowMutationUnsupported", defaultValue: "This browser window operation is not supported.")
        }
    }
}
