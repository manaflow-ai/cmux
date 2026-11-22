import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextTerminal
import CoreGraphics

/// Hover card and drag thumbnails of `TabContentCache` tabs.
extension TabContentCache {
    /// A tab's thumbnail. Terminals render one off the main thread. A browser
    /// page on screen is pictured on demand when its version moved since its
    /// last picture (once per navigation or load); a hidden one returns its
    /// last picture (the engine cannot picture it; nil: the card shows its
    /// placeholder). `captureIfMissing` (a tab drag) also asks for a hidden
    /// page that has none (Chromium gives none of a hidden page).
    func previewImage(for key: String, maxPixelSize: CGSize, captureIfMissing: Bool = false) async -> CGImage? {
        if let entry = terminals[key] {
            guard entry.session.showsOutput || entry.session.showsHeldFrame else { return nil } // a new shell's prompt: nothing to picture
            if let image = await entry.session.shownFrameInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) { previews.insert(image, for: key); return image }
        } else if let image = await lastFrames.preview(key)?.snapshot(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            return image // an evicted terminal: its last frame, pictured on demand
        }
        // A loaded page on screen whose picture is older (or gone) is pictured on demand, one capture
        // at a time; a hidden one keeps its last picture.
        if let entry = browsers[key], !pagePictureIsCurrent(entry, key: key),
           (shownPages.contains(key) && entry.tab.state.phase == .finished) || (captureIfMissing && pageThumbnails.image(for: key) == nil),
           let image = await capturePage(entry, key: key, accepts: { [weak self] in self?.browsers[key] === entry }) {
            return await PreviewImageCache.fit(image, maxPixelSize)
        }
        if let image = pageThumbnails.image(for: key) ?? previews.image(for: key) ?? hibernation?.snapshots.image(for: key) {
            // Leave pictures and hibernation pictures decode from their JPEG when drawn: the card gets a bitmap made
            // off the main thread, never a decode in its commit.
            return await PreviewImageCache.decoded(image, maxPixelSize)
        }
        return nil
    }

    /// R131: the hover card thumbnail of a page that left the screen. The
    /// engine capture (WKWebView takeSnapshot, CEF Page.captureScreenshot)
    /// starts on the main thread, so it happens once here, on leave, and
    /// never on a hover; the image is scaled off the main thread and kept
    /// in `pageThumbnails` only while this hide is still the tab's latest
    /// transition and the tab still has this page. Asked in this turn, before the hide: Chromium pictures no hidden page (P0 #1).
    func capturePagePreview(_ entry: BrowserEntry, key: String, token: ContentLifecycle<String>.Token) {
        guard let request = beginPageCapture(entry, key: key) else { return }
        Task { [weak self] in
            _ = await self?.finishPageCapture(request, key: key) { [weak self] in
                guard let self, self.browsers[key] === entry, self.lifecycle.accepts(key, token) else {
                    self?.trace(key, "preview \(token) dropped (stale)")
                    return false
                }
                return true
            }
        }
    }

    /// The page's picture is of its version now (`BrowserTabState.pictureVersion`) and still cached.
    func pagePictureIsCurrent(_ entry: BrowserEntry, key: String) -> Bool {
        pageThumbnails.image(for: key) != nil && pageThumbnailVersions[key] == entry.tab.state.pictureVersion
    }

    /// One engine capture of `entry` at a time (it starts on the main thread, under the capture deadline), kept with the
    /// version it was started at when `accepts`; a blank picture is kept without a version, so the next leave or hover tries again.
    private func capturePage(_ entry: BrowserEntry, key: String, accepts: @escaping () -> Bool) async -> CGImage? {
        guard let request = beginPageCapture(entry, key: key) else { return nil }
        return await finishPageCapture(request, key: key, accepts: accepts)
    }

    /// Asks the engine for `entry`'s picture in this turn, at most one per page at a time (`version`: the page's then).
    private func beginPageCapture(_ entry: BrowserEntry, key: String) -> (request: BrowserPictureRequest, version: Int)? {
        guard pageCapturesInFlight.insert(key).inserted else { return nil }
        return (entry.tab.beginThumbnail(), entry.tab.state.pictureVersion)
    }

    /// Awaits a capture ``beginPageCapture(_:key:)`` started, under the capture deadline, and keeps it when `accepts`.
    private func finishPageCapture(_ capture: (request: BrowserPictureRequest, version: Int), key: String, accepts: @escaping () -> Bool) async -> CGImage? {
        defer { pageCapturesInFlight.remove(key) }
        let version = capture.version, budget = pageCaptureDeadline
        guard let image = try? await ControlDeadline.shared.run(method: "preview.capture", deadline: .now + budget, { @MainActor in
            try await capture.request.image()
        }) else { return nil }
        let fitted = await PreviewImageCache.fit(image, PreviewImageCache.pagePixelSize)
        let blank = await ThumbnailStats.measure(fitted)?.isBlank == true
        guard accepts() else { return nil }
        // Kept compressed, once per tab, for the tab's life: a hibernated Chromium tab wakes to it (fork API 24 pictures
        // no hidden page); decoded 640 px pictures in the 16 MB budget kept only about 14 pages' (fleet e2fb152d, 05f0ba3c).
        pageThumbnails.insertCompressingLater(fitted, for: key)  // nobody who waits for this picture waits for its encode
        pageThumbnailVersions[key] = blank ? nil : version
        return image
    }

    /// The window holding `presenters` stopped being key (another window or
    /// app took the keyboard): each page they show on screen is captured
    /// once, so a hover from another window shows it (R131).
    /// Same scaling and staleness rules as the leave capture: the token is
    /// the page's current transition, so a hide, show or close before the
    /// capture lands drops it.
    func windowDidResignKey(presenters: [any SurfacePresenter]) {
        for presenter in presenters {
            for key in ledger.keys(ownedBy: ObjectIdentifier(presenter)) where ledger.isRendering(key) {
                guard let entry = browsers[key], !pagePictureIsCurrent(entry, key: key),
                      let generation = lifecycle.record(key)?.generation else { continue }
                capturePagePreview(entry, key: key, token: ContentLifecycle<String>.Token(generation))
            }
        }
    }
}
