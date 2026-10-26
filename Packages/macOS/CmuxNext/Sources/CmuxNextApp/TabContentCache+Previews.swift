import AppKit
import Carbon.HIToolbox
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextTerminal
import CmuxNextWakeups
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
            guard entry.session.showsOutput else { return nil } // a new shell's prompt: nothing to picture
            if let image = await entry.session.snapshotInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) { previews.insert(image, for: key); return image }
        } else if let image = await lastFrames[key]?.snapshot(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) {
            return image // an evicted terminal: its last frame, pictured on demand
        }
        // A loaded page on screen whose picture is older (or gone) is pictured on demand, one capture
        // at a time, while the thumbnails can keep it; a hidden one keeps its last picture.
        if let entry = browsers[key], !pagePictureIsCurrent(entry, key: key),
           (shownPages.contains(key) && entry.tab.state.phase == .finished && keepsPageThumbnails)
            || (captureIfMissing && pageThumbnails.image(for: key) == nil),
           let image = await capturePage(entry, key: key, accepts: { [weak self] in self?.browsers[key] === entry }) {
            return await TabPreviewFitting.fit(image, maxPixelSize)
        }
        if let image = pageThumbnails.image(for: key) ?? previews.image(for: key) ?? internalPagePictures.image(for: key)
            ?? hibernation?.snapshots.image(for: key) {
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
        guard keepsPageThumbnails else { return }
        Task { [weak self] in
            _ = await self?.capturePage(entry, key: key) { [weak self] in
                guard let self, self.browsers[key] === entry, self.lifecycle.accepts(key, token) else {
                    self?.trace(key, "preview \(token) dropped (stale)")
                    return false
                }
                return true
            }
        }
    }

    /// The thumbnails would keep a page's picture now. Not at the critical memory limit, where a kept-nothing
    /// capture would start again on every hover, leave and resign-key: the main-thread engine capture is skipped.
    var keepsPageThumbnails: Bool { pageThumbnails.fits(bytes: TabPreviewFitting.cachedThumbnailBytes) }

    /// The page's picture is of its version now (`pageVersion`) and still cached.
    func pagePictureIsCurrent(_ entry: BrowserEntry, key: String) -> Bool {
        pageThumbnails.image(for: key) != nil && pageThumbnailVersions[key] == Self.pageVersion(entry)
    }

    /// One engine capture of `entry` at a time (it starts on the main thread, under the capture
    /// deadline), kept with the version it was started at when `accepts`; a blank picture is kept
    /// without a version, so the next leave or hover tries again.
    private func capturePage(_ entry: BrowserEntry, key: String, accepts: @escaping () -> Bool) async -> CGImage? {
        guard pageCapturesInFlight.insert(key).inserted else { return nil }
        defer { pageCapturesInFlight.remove(key) }
        let page = entry.tab, version = Self.pageVersion(entry), budget = pageCaptureDeadline
        guard let image = try? await ControlDeadline.shared.run(method: "preview.capture", deadline: .now + budget, { @MainActor in
            try await page.thumbnail()
        }) else { return nil }
        let fitted = await TabPreviewFitting.fit(image, TabPreviewFitting.cachedPixelSize)
        guard accepts() else { return nil }
        pageThumbnails.insert(fitted, for: key)
        pageThumbnailVersions[key] = await ThumbnailStats.measure(fitted)?.isBlank == true ? nil : version
        return image
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
                guard let entry = browsers[key], !pagePictureIsCurrent(entry, key: key),
                      let generation = lifecycle.record(key)?.generation else { continue }
                capturePagePreview(entry, key: key, token: ContentLifecycle<String>.Token(generation))
            }
        }
    }
}

/// The browser pages' pictures from the last quit (`BrowserLaunchPictures`, p08-startup-043): saved at quit for
/// the pages on screen, drawn over their panes at launch until each page shows its first content.
extension TabContentCache {
    /// Uses the launch's read of the pictures when the feature `browserLaunchPictures` is on, and drops the ones no
    /// pane took 30 s on; with it off the read's pictures go at once (the quit then deletes them from disk).
    func useLaunchPictures(_ pictures: BrowserLaunchPictures?, enabled: Bool, deadlines: MainDeadlineScheduler) {
        guard let pictures else { return }
        guard enabled else { return pictures.dropUnasked() }
        launchPictures = pictures
        pictures.dropUnasked(after: .seconds(30), on: MainDeadline(owner: "browser.launch-pictures.keep", workClass: .background,
                                                                   scheduler: deadlines))
    }

    /// Shows tab `key`'s page picture from the last quit over `pane`, at once, never waiting for the read, the
    /// page or its engine: a Chromium page made after the first frame shows the picture until then, and every page
    /// until its first content frame. A later call for the same tab (its page arrived) keeps the picture over the
    /// page and follows the page's first content. Returns whether the pane shows one now.
    @discardableResult
    func showLaunchPicture(_ key: String, in pane: PaneContentView, hold: LaunchImageHold, reveal: LaunchReveal) -> Bool {
        if (pane.launchImageView as? BrowserLaunchPictureView)?.tab != key {
            // A crash streak's deferred pages load nothing: no picture would ever be replaced.
            guard let launchPictures, !defersRestoredPages,
                  let picture = launchPictures.take(key, profile: (browserProfile?(key) ?? .default).rawValue) else { return false }
            pane.showLaunchPicture(BrowserLaunchPictureView(picture, tab: key), hold: hold)
            reveal.release(pane.contentHost)  // its data is here before the pane region's
            DebugTimings.markLaunch("browser.launch_picture_shown")
        }
        guard let view = pane.launchImageView as? BrowserLaunchPictureView else { return false }
        // Over the browser installed since: its toolbar and theme color draw over anything under them.
        if pane.contentHost.subviews.last !== view { pane.contentHost.addSubview(view, positioned: .above, relativeTo: nil) }
        if let page = browsers[key]?.tab as? any BrowserFirstContentFrameReporting, view.waits(for: page) {
            page.whenFirstContentFrame { [weak pane, weak view] _ in
                guard let pane, let view, pane.launchImageView === view else { return }
                pane.clearLaunchImage()
            }
        }
        return true
    }

    /// The pictures of the pages `panes` show now (each its tab and its content area), for the next launch. One
    /// engine capture at a time, all within one capture deadline; nothing of a withheld page is captured.
    func launchPictureShots(_ panes: [(key: String, host: NSView)]) async -> [BrowserLaunchPictures.Shot] {
        let deadline = ContinuousClock.now + pageCaptureDeadline
        var shots: [BrowserLaunchPictures.Shot] = []
        for pane in panes {
            if let shot = await launchPictureShot(pane.key, in: pane.host, deadline: deadline) { shots.append(shot) }
        }
        return shots
    }

    /// Tab `key`'s page as `host` shows it: nil for no engine page (none yet, deferred, asleep, a cmux page), one
    /// not on screen, or one whose picture is withheld (`BrowserLaunchPictures.Withheld`).
    private func launchPictureShot(_ key: String, in host: NSView, deadline: ContinuousClock.Instant) async -> BrowserLaunchPictures.Shot? {
        guard let page = browsers[key]?.tab, page is any BrowserFirstContentFrameReporting else { return nil }
        let view = page.contentView
        guard let window = view.window, VisiblePaneRefs.Window.isOnScreen(view), view.isDescendant(of: host),
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        var withheld: BrowserLaunchPictures.Withheld = []
        if chromium.stores.offTheRecord.isOffTheRecord(page.profileID) || browserTabs.isIncognitoTab(key) { withheld.insert(.offTheRecord) }
        if IsSecureEventInputEnabled(), let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { withheld.insert(.secureInput) }
        if let tab = tabModel(key), browserTabs.reopenedForProtectedMedia(tab) { withheld.insert(.protectedMedia) }
        if window.sharingType == .none { withheld.insert(.hiddenFromCapture) }
        guard withheld.isEmpty else { return nil }
        // The geometry before the capture: the pane may change while it runs.
        let frame = view.convert(view.bounds, to: host), paneSize = host.bounds.size
        let top = host.isFlipped ? frame.minY : paneSize.height - frame.maxY
        guard let image = try? await ControlDeadline.shared.run(method: "launch-picture.capture", deadline: deadline, { @MainActor in
            try await page.snapshot()
        }) else { return nil }
        let picture = BrowserLaunchPictures.Picture(image: image, paneSize: paneSize,
                                                    pageFrame: CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height))
        return BrowserLaunchPictures.Shot(key: key, profile: page.profileID.rawValue, withheld: withheld, picture: picture)
    }
}
