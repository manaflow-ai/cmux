import CoreGraphics

/// The leave-time tab thumbnail of a Chromium page.
///
/// `Page.captureScreenshot` encodes the image in the browser process on its
/// UI thread, which is the app's main thread (`CEFMessagePump`). A full
/// viewport PNG of a real page took 80-140 ms there (browser perf report,
/// root cause R3), once per tab switch. A fast-mode JPEG of the same
/// pixels takes about a quarter of that and is plenty for a thumbnail that
/// `TabPreviewFitting` scales down anyway. A clip with a scale is slower
/// still: Chromium lays the page out again for it.
nonisolated enum CEFThumbnail {
    static let params: [String: Any] = ["format": "jpeg", "quality": 70, "optimizeForSpeed": true]
}

extension CEFTab {
    public func thumbnail() async throws -> CGImage {
        guard let browserID, !isClosed else { throw BrowserTabError.snapshotUnavailable }
        let json = try await runtime.devTools(browserID, method: "Page.captureScreenshot", params: CEFThumbnail.params)
        return try CEFDevToolsResult.screenshot(json)
    }
}
