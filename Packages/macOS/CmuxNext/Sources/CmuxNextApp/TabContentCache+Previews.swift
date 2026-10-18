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
    /// placeholder). `captureIfMissing` (a tab drag) also pictures a hidden
    /// page that has none.
    func previewImage(for key: String, maxPixelSize: CGSize, captureIfMissing: Bool = false) async -> CGImage? {
        if let entry = terminals[key] {
            guard TerminalOutput.shows(entry.session) else { return nil } // a new shell's prompt: nothing to picture
            if let image = await entry.session.snapshotInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) { previews.insert(image, for: key); return image }
        }
        // A page on screen whose picture is of an older version (or none) is pictured on demand; a
        // hidden one keeps its last picture.
        if let entry = browsers[key], shownPages.contains(key) || (captureIfMissing && pageThumbnails.image(for: key) == nil),
           pageThumbnailVersions[key] != Self.pageVersion(entry), let image = try? await entry.tab.thumbnail() {
            let fitted = await TabPreviewFitting.fit(image, TabPreviewFitting.cachedPixelSize)
            if browsers[key] === entry { pageThumbnails.insert(fitted, for: key); pageThumbnailVersions[key] = Self.pageVersion(entry) }
            return await TabPreviewFitting.fit(image, maxPixelSize)
        }
        if let image = pageThumbnails.image(for: key) ?? previews.image(for: key) {
            return await TabPreviewFitting.fit(image, maxPixelSize)
        }
        return nil
    }

    /// R131: the hover card thumbnail of a page that left the screen. The
    /// engine capture (WKWebView takeSnapshot, CEF Page.captureScreenshot)
    /// starts on the main thread, so it happens once here, on leave, and
    /// never on a hover; the image is scaled off the main thread and kept
    /// in `pageThumbnails` only while this hide is still the tab's latest
    /// transition and the tab still has this page.
    func capturePagePreview(_ entry: BrowserEntry, key: String, token: ContentLifecycle<String>.Token) {
        let page = entry.tab, version = Self.pageVersion(entry)
        let budget = pageCaptureDeadline
        Task { [weak self] in
            let image = try? await ControlDeadline.shared.run(method: "preview.capture", deadline: .now + budget) { @MainActor in
                try await page.thumbnail()
            }
            guard let image else { return }
            let fitted = await TabPreviewFitting.fit(image, TabPreviewFitting.cachedPixelSize)
            guard let self, self.browsers[key]?.tab === page, self.lifecycle.accepts(key, token) else {
                self?.trace(key, "preview \(token) dropped (stale)")
                return
            }
            self.pageThumbnails.insert(fitted, for: key)
            self.pageThumbnailVersions[key] = version
        }
    }

    /// What a page's picture shows, as navigation and load events tell it: its URL, title and
    /// whether its load finished. Scrolling or typing in the page does not move it.
    static func pageVersion(_ entry: BrowserEntry) -> Int {
        let state = entry.tab.state
        var hasher = Hasher()
        hasher.combine(state.url)
        hasher.combine(state.title)
        hasher.combine(state.phase == .finished)
        return hasher.finalize()
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
                guard let entry = browsers[key], pageThumbnailVersions[key] != Self.pageVersion(entry),
                      let generation = lifecycle.record(key)?.generation else { continue }
                capturePagePreview(entry, key: key, token: ContentLifecycle<String>.Token(generation))
            }
        }
    }
}
