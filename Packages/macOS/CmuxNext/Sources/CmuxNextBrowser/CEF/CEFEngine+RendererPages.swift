import Foundation

/// One live Chromium page (a browser tab or one of cmux's own pages, such as the agent page) and
/// the renderer processes that host its frames (`debug.cef_pages`).
public nonisolated struct CEFRendererPage: Sendable, Equatable {
    public var browserID: Int32
    /// The page URL's scheme and host (`cmux-page://cmux.agent`, `http://t3.localhost`), never its
    /// path or query.
    public var origin: String
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
            return CEFRendererPage(browserID: browser, origin: Self.origin(of: tab.state.url),
                                   hidden: tab.isContentHidden, rendererClients: clients)
        }
    }

    nonisolated static func origin(of url: URL?) -> String {
        guard let url, let scheme = url.scheme else { return "" }
        guard let host = url.host(), !host.isEmpty else { return scheme + ":" }
        return "\(scheme)://\(host)"
    }
}
