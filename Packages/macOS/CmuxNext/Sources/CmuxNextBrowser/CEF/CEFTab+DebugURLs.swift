import Foundation

extension CEFTab {
    /// Chromium's debug URLs, which a load runs at once and which start no navigation: no load
    /// start, commit or load end follows, so ``load(_:)`` keeps the tab's page and address.
    /// Renderer ones (third_party/blink/common/chrome_debug_urls.cc, `IsRendererDebugURL`) go to the
    /// page's renderer, browser ones (content/browser/renderer_host/debug_urls.cc, `HandleDebugURL`)
    /// to the browser or GPU process; `NavigationControllerImpl::NavigateWithoutEntry` returns no
    /// navigation for either.
    nonisolated static let debugURLHosts: Set<String> = [
        // Renderer debug URLs.
        "badcastcrash", "checkcrash", "crash", "crashdump", "hang", "kill", "memory-exhaust", "shorthang",
        // Browser debug URLs.
        "delayeduithreadhang", "gpuclean", "gpucrash", "gpuhang", "inducebrowsercrashforrealz",
        "memory-pressure-critical", "memory-pressure-moderate", "uithreadhang",
    ]

    /// Whether `url` is one of ``debugURLHosts`` in the exact form Chromium compares (`chrome://crash/`,
    /// GURL's canonical `chrome://crash` included): a path, query or fragment makes it a page load.
    nonisolated static func isDebugURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "chrome", let host = url.host()?.lowercased(), debugURLHosts.contains(host),
              url.query() == nil, url.fragment() == nil else { return false }
        return url.path().isEmpty || url.path() == "/"
    }

    /// Sends `url` to Chromium when it is a debug URL of a tab with a browser (true): no navigation
    /// starts, so the tab's state is not touched. A tab still making its browser loads it as a page.
    func loadsDebugURL(_ url: URL) -> Bool {
        guard let browserID, Self.isDebugURL(url) else { return false }
        runtime.shim?.loadURL(browserID, url.absoluteString)
        return true
    }
}
