public import AppKit
import Foundation

/// One live Chromium page (a browser tab or one of cmux's own pages, such as the agent page) and
/// the renderer processes that host its frames (`debug.cef_pages`).
public nonisolated struct CEFRendererPage: Sendable, Equatable {
    public var browserID: Int32
    /// The page URL's scheme and host (`cmux-page://cmux.agent`, `http://t3.localhost`), never its
    /// path or query.
    public var origin: String
    /// The full page URL and title, for `renderers.list` (`cmux app renderers`), which names the
    /// page a busy renderer pid hosts. `debug.cef_pages` keeps reporting only ``origin``.
    public var url: String = ""
    public var title: String = ""
    /// The content lifecycle hid the page (a background tab, a parked page).
    public var hidden: Bool
    /// Renderer client ids (the `--renderer-client-id=` of the helper processes that host its frames).
    public var rendererClients: [Int32]
}

extension CEFEngine {
    /// Every live Chromium page, by browser id, so a bench can name each renderer process's role
    /// (scripts/cmux-next/bench_power.py, scenario `loaded`). Read on request only: one shim call
    /// per page, no observation and no timer.
    public var rendererPages: [CEFRendererPage] {
        CEFRuntime.shared.tabsByBrowser.sorted { $0.key < $1.key }.map { browser, tab in
            let clients: [Int32] = if case .chromiumRendererClients(let ids) = tab.contentProcesses { ids } else { [] }
            var page = CEFRendererPage(browserID: browser, origin: Self.origin(of: tab.state.url),
                                       hidden: tab.isContentHidden, rendererClients: clients)
            page.url = tab.state.url?.absoluteString ?? ""
            page.title = tab.state.title ?? ""
            return page
        }
    }

    /// Runs DevTools `method` on the live page `browserID` (`debug.cef_page_devtools`: the idle
    /// bench's page metrics and CPU profile). Nil when no live page has that id.
    public func devTools(browserID: Int32, method: String, params: [String: any Sendable]) async throws -> String? {
        guard let tab = CEFRuntime.shared.tabsByBrowser[browserID] else { return nil }
        return try await tab.devTools(method: method, params: params)
    }

    /// The browser id of the live page whose content view is `view` (a cmux page's Chromium view,
    /// such as an agent pane's ``focusTarget``), so `renderers.list` can name its owning tab.
    public func browserID(showing view: NSView) -> Int32? {
        CEFRuntime.shared.tabsByBrowser.first { $0.value.contentView === view }?.key
    }

    nonisolated static func origin(of url: URL?) -> String {
        guard let url, let scheme = url.scheme else { return "" }
        guard let host = url.host(), !host.isEmpty else { return scheme + ":" }
        return "\(scheme)://\(host)"
    }
}
