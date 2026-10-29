public import CoreGraphics

/// The leave-time tab thumbnail of a Chromium page.
///
/// `Page.captureScreenshot` encodes the image in the browser process on its
/// UI thread, which is the app's main thread (`CEFMessagePump`). A full
/// viewport PNG of a real page took 80-140 ms there (browser perf report,
/// root cause R3), once per tab switch. A fast-mode JPEG of the same
/// pixels takes about a quarter of that and is plenty for a thumbnail that
/// `TabPreviewFitting` scales down anyway. A clip with a scale is slower
/// still: Chromium lays the page out again for it.
///
/// A picture is asked for only while the page's browser lives and the engine is not stopping, and the app's own
/// pictures (thumbnails: leave, hover, drag, hibernation) only while the page shows (``mayPicture(_:evenHidden:)``).
/// Chromium copies a hidden page's surface only to fail and retry, and a renderer that exited while a copy was in
/// flight crashed the browser process (P0 #1, 2026-10-28: SIGSEGV in
/// `RenderWidgetHostImpl::OnSnapshotFromSurfaceReceived`, 19 of 21 reports in the quit; the fork's
/// `cmux_snapshot_view_gone` patch fixes Chromium itself). A browser that closes before the answer ends the
/// wait with `closed` and its late answer is dropped (``CEFRuntime/result(of:method:timeout:)``).
enum CEFThumbnail {
    nonisolated static var params: [String: Any] { ["format": "jpeg", "quality": 70, "optimizeForSpeed": true] }
    /// `snapshot()`: full-fidelity PNG.
    nonisolated static var png: [String: Any] { ["format": "png"] }

    /// Whether `tab` may be pictured now: its browser lives, the engine is not stopping (quit began) and, unless
    /// `evenHidden` (a person's or an agent's own screenshot, ``CEFTab/snapshot()``: DevTools keeps a hidden page
    /// drawing for it), the page shows (the content lifecycle did not hide it).
    @MainActor static func mayPicture(_ tab: CEFTab, evenHidden: Bool) -> Bool {
        tab.browserID != nil && !tab.isClosed && (evenHidden || !tab.isContentHidden) && tab.runtime.acceptsNewBrowsers
    }

    /// One `Page.captureScreenshot` of `tab`, sent now, in the caller's turn (here, not in CEFTab, which is at its
    /// type-size limit); a refused one sends nothing.
    @MainActor static func start(_ tab: CEFTab, _ params: [String: Any], evenHidden: Bool) -> BrowserPictureRequest {
        guard mayPicture(tab, evenHidden: evenHidden), let browserID = tab.browserID,
              let sent = tab.runtime.sendDevTools(browserID, method: "Page.captureScreenshot", params: params) else {
            return .refused(.snapshotUnavailable)
        }
        let runtime = tab.runtime
        return BrowserPictureRequest { [weak tab] in
            let json = try await runtime.result(of: sent, method: "Page.captureScreenshot")
            // The answer is for a page that may have gone meanwhile: nothing of a closed page is kept.
            guard let tab, !tab.isClosed else { throw BrowserTabError.closed }
            return try CEFDevToolsResult.screenshot(json)
        }
    }
}

extension CEFTab {
    public func snapshot() async throws -> CGImage { try await CEFThumbnail.start(self, CEFThumbnail.png, evenHidden: true).image() }
    public func thumbnail() async throws -> CGImage { try await beginThumbnail().image() }
    public func beginThumbnail() -> BrowserPictureRequest { CEFThumbnail.start(self, CEFThumbnail.params, evenHidden: false) }
}
