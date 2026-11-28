import Foundation

/// Tab favicons through the tab's own Chromium request context (cx-d0d.8): CEF's
/// `DownloadImage` as a favicon fetch, so an icon behind a cookie-auth origin loads as the
/// page saw it, from Chromium's cache when it has it. Main thread (the CEF UI thread).
extension CEFRuntime {
    /// The PNG of the favicon at `url` as tab `browser` fetches it, at most `maxPixels`
    /// square; nil when the browser is gone, the fetch failed or nothing decoded.
    func favicon(_ browser: Int32, url: URL, maxPixels: Int) async -> Data? {
        let reply = try? await siteCall(browser, what: "favicon download") { shim, id in
            shim.downloadFavicon(browser, id, url.absoluteString, Int32(maxPixels))
        }
        return reply.flatMap { Data(base64Encoded: $0.json) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
