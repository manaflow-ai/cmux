import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextTerminal
import CoreGraphics

/// Hover card and drag thumbnails of `TabContentCache` tabs.
extension TabContentCache {
    /// A tab's thumbnail. Terminals render one off the main thread. A
    /// browser page returns the image captured when it last left the screen
    /// (nil if it never did: the card shows its placeholder); an engine
    /// capture starts on the main thread, so a hover never starts one (R131).
    /// `captureIfMissing` (a tab drag, never a hover) captures a page that
    /// has no cached image.
    func previewImage(for key: String, maxPixelSize: CGSize, captureIfMissing: Bool = false) async -> CGImage? {
        if let entry = terminals[key],
           let image = await entry.session.snapshotInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            previews.insert(image, for: key)
            return image
        }
        if let image = pageThumbnails.image(for: key) ?? previews.image(for: key) {
            return await TabPreviewFitting.fit(image, maxPixelSize)
        }
        if captureIfMissing, let entry = browsers[key], let image = try? await entry.tab.snapshot() {
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
        let page = entry.tab
        Task { [weak self] in
            let image = try? await ControlDeadline.shared.run(method: "preview.capture", deadline: .now + .seconds(2)) { @MainActor in
                try await page.snapshot()
            }
            guard let image else { return }
            let fitted = await TabPreviewFitting.fit(image, TabPreviewFitting.cachedPixelSize)
            guard let self, self.browsers[key]?.tab === page, self.lifecycle.accepts(key, token) else {
                self?.trace(key, "preview \(token) dropped (stale)")
                return
            }
            self.pageThumbnails.insert(fitted, for: key)
        }
    }

    /// The window holding `presenters` stopped being key (another window or
    /// app took the keyboard): each page they show on screen is captured
    /// once, so a hover from another window shows it (R131).
    func windowDidResignKey(presenters: [any SurfacePresenter]) {}
}
