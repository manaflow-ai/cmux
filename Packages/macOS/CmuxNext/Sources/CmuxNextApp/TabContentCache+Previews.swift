import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextTerminal
import CoreGraphics
import Foundation

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

    /// Asks the engine for `entry`'s picture in this turn, at most one per page at a time (`version`, `url`: the page's then).
    private func beginPageCapture(_ entry: BrowserEntry, key: String) -> (request: BrowserPictureRequest, version: Int, url: String?)? {
        guard pageCapturesInFlight.insert(key).inserted else { return nil }
        return (entry.tab.beginThumbnail(), entry.tab.state.pictureVersion, entry.tab.state.url?.absoluteString)
    }

    /// Awaits a capture ``beginPageCapture(_:key:)`` started, under the capture deadline, and keeps it when `accepts`.
    private func finishPageCapture(_ capture: (request: BrowserPictureRequest, version: Int, url: String?), key: String, accepts: @escaping () -> Bool) async -> CGImage? {
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
        pageThumbnailVersions[key] = blank ? nil : version; pageThumbnailURLs[key] = blank ? nil : capture.url
        if !blank {
            keepFrameOnDisk(image, for: key) // also the picture the next launch shows first
            phonePictures?.offerThumbnail(image, tab: key)
        }
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

/// A restored browser tab shows its page's last picture from the run before in the frame of its first show (Leo
/// 2026-11-22: "constant rerenders on every fucking page still"): `BrowserPageFrames`, then the new page under it.
extension TabContentCache {
    /// A cold load after a relaunch takes seconds, a wake hundreds of ms (`BrowserHibernation.standInCap`).
    static let relaunchStandInCap: Duration = .seconds(3)
    /// A browser page that is not incognito.
    func keepsFrameOnDisk(_ key: String) -> Bool {
        guard let page = browsers[key]?.tab, page is CEFTab || page is WebKitTab else { return false }
        return !cef.stores.offTheRecord.isOffTheRecord(page.profileID) && !browserTabs.isIncognitoTab(key) && !browserTabs.isSignInApprovalTab(key)
    }
    func keepFrameOnDisk(_ image: CGImage, for key: String) {
        guard keepsFrameOnDisk(key), let width = browsers[key]?.tab.contentView.bounds.width else { return }
        pageFrames?.save(image, for: key, scale: BrowserPageFrames.scale(of: image, width: width))
    }

    /// The stand-in page of restored Chromium tab `tab` while its page is made; nil for a tab opened here.
    func restoringStandIn(_ tab: TabModel, url: URL?) -> DeferredBrowserTab? {
        guard !browserTabs.wasOpenedHere(tab), browsers[tab.id] == nil else { return nil }
        let page = DeferredBrowserTab(id: BrowserTabID(rawValue: tab.id), engine: .cef, profile: browserProfile?(tab.id) ?? .default, url: url,
                                      title: tab.titleText.isEmpty ? nil : tab.titleText, picture: pageFrames?.take(tab.id), restoresPage: true)
        install(page, for: tab.id)
        return page
    }

    /// A restored tab's page made now (WebKit): its last picture covers it until it paints.
    func coverRestored(_ entry: BrowserEntry, _ tab: TabModel) -> BrowserEntry {
        if !browserTabs.wasOpenedHere(tab), let picture = pageFrames?.take(tab.id) {
            (entry.tab as? any BrowserWakeStandIn)?.showStandIn(picture, decoded: true, cap: Self.relaunchStandInCap, clock: ContinuousClock())
        }
        return entry
    }

    /// Whether `key` shows a restored tab's stand-in while its page is made (automation waits for the page).
    func isRestoring(_ key: String) -> Bool { (browsers[key]?.tab as? DeferredBrowserTab)?.restoresPage == true }

    /// The quit: the pages on screen are pictured (under the capture deadline) and written for the next launch.
    func savePageFramesForQuit() async {
        guard let pageFrames else { return }
        var images: [String: (image: CGImage, scale: Int)] = [:]
        // Every capture asked in this turn, so they run at once.
        let requests = shownPages.filter(keepsFrameOnDisk).compactMap { key in browsers[key].map { (key, $0.tab.beginThumbnail(), $0.tab.contentView.bounds.width) } }
        for (key, request, width) in requests {
            guard let image = try? await ControlDeadline.shared.run(method: "preview.capture", deadline: .now + pageCaptureDeadline, { @MainActor in
                try await request.image()
            }), await ThumbnailStats.measure(image)?.isBlank != true else { continue }
            images[key] = (image, BrowserPageFrames.scale(of: image, width: width))
        }
        await pageFrames.saveForQuit(images)
    }
}
