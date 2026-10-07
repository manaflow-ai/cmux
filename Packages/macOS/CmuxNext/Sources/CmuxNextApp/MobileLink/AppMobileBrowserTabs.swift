import AppKit
import CmuxBrowserStream
import CmuxMobileHost
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextMobileHostUI
import Observation

/// The app's browser tabs for the phone link (C2, c2-browser-stream.md 9):
/// a browser tab of a local workspace, not incognito, whose page is live.
/// Pixels come from the window that shows it: the page's own child window
/// for Chromium (`.childWindow` presentation), else the pane's window
/// cropped to the page view.
final class AppMobileBrowserTabs: MobileBrowserTabs {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func tab(_ id: String) -> (any MobileBrowserTab)? {
        guard let services else { return nil }
        let cache: TabContentCache = services.cache
        let isLocalBrowserTab = services.daemon.store.workspaces.contains { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == id && $0.kind == .browser } } }
        }
        guard isLocalBrowserTab, cache.browserTabs.isIncognitoTab(id) == false, let page = cache.existingBrowser(id)?.tab else {
            return nil
        }
        return AppMobileBrowserTab(page: page)
    }
}

/// One live page (`BrowserTab`) as the phone stream sees it.
final class AppMobileBrowserTab: MobileBrowserTab {
    // Not `page`: that name is the protocol's `RbPage` snapshot below, and
    // Swift 6.2 rejects a stored property and a computed one sharing it.
    private let browserTab: any BrowserTab

    init(page: any BrowserTab) {
        browserTab = page
    }

    var placement: MobileBrowserPlacement? {
        let view = browserTab.contentView
        guard let window = view.window, window.isVisible else { return nil }
        let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        if browserTab.presentation == .childWindow,
           let child = window.childWindows?.first(where: { $0.isVisible && $0.frame.insetBy(dx: -2, dy: -2).contains(onScreen) }) {
            return MobileBrowserPlacement(windowID: CGWindowID(child.windowNumber),
                                          rect: CGRect(origin: .zero, size: child.frame.size))
        }
        let inWindow = view.convert(view.bounds, to: nil)
        let topLeft = CGRect(x: inWindow.minX, y: window.frame.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        return MobileBrowserPlacement(windowID: CGWindowID(window.windowNumber), rect: topLeft)
    }

    var geometry: BrowserPageGeometry {
        let size = browserTab.contentView.bounds.size
        let zoom = max(browserTab.state.zoom, 0.25)
        return BrowserPageGeometry(cssWidth: Double(size.width) / zoom, cssHeight: Double(size.height) / zoom,
                                   backingScale: Double(browserTab.contentView.window?.backingScaleFactor ?? 2) * zoom)
    }

    var page: RbPage {
        let state = browserTab.state
        return RbPage(url: state.url?.absoluteString ?? "about:blank", title: state.title ?? "", loading: state.isLoading,
                      canGoBack: state.canGoBack, canGoForward: state.canGoForward)
    }

    func changes() -> AsyncStream<Void> {
        let browserTab = browserTab
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Page state only: pane resizes reach the phone with the next page change.
            // task-owner: one per attached phone; ends when the phone detaches (stream terminated).
            let task = Task { @MainActor in
                for await _ in Observations({ browserTab.state }) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func devTools(method: String, params: [String: any Sendable]) async throws {
        guard let chromium = browserTab as? CEFTab else { throw BrowserPageError.failed("this page takes no remote input") }
        _ = try await chromium.devTools(method: method, params: params)
    }

    func load(_ url: URL) { browserTab.load(url) }
    func goBack() { browserTab.goBack() }
    func goForward() { browserTab.goForward() }
    func reload() { browserTab.reload() }
    func stopLoading() { browserTab.stop() }
}
