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
    /// placeholder). `captureIfMissing` (a tab drag) also asks for a hidden
    /// page that has none (Chromium gives none of a hidden page).
    func previewImage(for key: String, maxPixelSize: CGSize, captureIfMissing: Bool = false) async -> CGImage? {
        if let entry = terminals[key] {
            guard entry.session.showsOutput else { return nil } // a new shell's prompt: nothing to picture
            if let image = await entry.session.shownFrameInBackground(maxPixelSize: max(maxPixelSize.width, maxPixelSize.height)) { previews.insert(await previews.picture(of: image), for: key); return image }
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
    /// transition and the tab still has this page. The engine is asked in this
    /// turn, before the conceal hides the page: Chromium pictures only a shown
    /// page, and a copy of a hidden one crashed it (P0 #1, 2026-10-28).
    func capturePagePreview(_ entry: BrowserEntry, key: String, token: ContentLifecycle<String>.Token) {
        guard keepsPageThumbnails, pageCapturesInFlight.insert(key).inserted else { return }
        let request = entry.tab.beginThumbnail(), version = Self.pageVersion(entry)
        // The capture awaits the engine: the task is nonisolated, and the capture's main steps are the engine's.
        Task { @concurrent [weak self] in await self?.capturePagePreviewNow(request, version: version, entry: entry, key: key, token: token) }
    }

    /// The capture ``capturePagePreview(_:key:token:)`` started, kept only while `token` is the tab's latest transition.
    private func capturePagePreviewNow(_ request: BrowserPictureRequest, version: Int, entry: BrowserEntry, key: String,
                                       token: ContentLifecycle<String>.Token) async {
        _ = await finishPageCapture(request, version: version, key: key) { [weak self] in
            guard let self, self.browsers[key] === entry, self.lifecycle.accepts(key, token) else {
                self?.trace(key, "preview \(token) dropped (stale)")
                return false
            }
            return true
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
        return await finishPageCapture(entry.tab.beginThumbnail(), version: Self.pageVersion(entry), key: key, accepts: accepts)
    }

    /// Awaits a capture `key` has in flight (asked for at page `version`) and keeps it when `accepts`; then ends it.
    private func finishPageCapture(_ request: BrowserPictureRequest, version: Int, key: String,
                                   accepts: @escaping () -> Bool) async -> CGImage? {
        defer { pageCapturesInFlight.remove(key) }
        let budget = pageCaptureDeadline
        guard let image = try? await ControlDeadline.shared.run(method: "preview.capture", deadline: .now + budget, { @MainActor in
            try await request.image()
        }) else { return nil }
        let fitted = await TabPreviewFitting.fit(image, TabPreviewFitting.cachedPixelSize)
        let picture = await pageThumbnails.picture(of: fitted)
        guard accepts() else { return nil }
        pageThumbnails.insert(picture, for: key)
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

/// The browser pages' pictures from the last quit (`BrowserLaunchPictures`): saved at quit for
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
            // A page in its own window (Chromium) would draw over the picture from its commit: a hole while it shows.
            if let covered = page as? any BrowserPageCovering {
                view.onShowsChange = { [weak covered] shows in covered?.isPageCovered = shows }
            }
            page.whenFirstContentFrame { [weak pane, weak view] _ in
                guard let pane, let view, pane.launchImageView === view else { return }
                pane.clearLaunchImage()
            }
        }
        return true
    }

    /// The tabs whose page holds the keyboard while Secure Input is on (a password field). The quit reads them as
    /// it begins, before a quit dialog takes the keyboard (p08-startup 3C: their pictures are never taken).
    func secureInputPages() -> Set<String> {
        secureInputPages(secureInput: IsSecureEventInputEnabled(), keyWindow: NSApp.keyWindow)
    }

    /// ``secureInputPages()`` with Secure Input on or off and `keyWindow` the app's key window (seams for tests). A
    /// Chromium page holds the keyboard as a key child window of its window (`BrowserTab.holdsKeyboard`).
    func secureInputPages(secureInput: Bool, keyWindow: NSWindow?) -> Set<String> {
        guard secureInput else { return [] }
        return Set(browsers.compactMap { key, entry in
            guard let window = entry.tab.contentView.window, entry.tab.holdsKeyboard(in: window, keyWindow: keyWindow) else { return nil }
            return key
        })
    }

    /// The pictures of the pages `panes` show now (each its tab and its content area), for the next launch. One
    /// engine capture at a time, all within one capture deadline; nothing of a withheld page is captured.
    /// `secureInput`: the tabs that held Secure Input when the quit began (``secureInputPages()``); the ones that
    /// hold it now are withheld too.
    func launchPictureShots(_ panes: [(key: String, host: NSView)], secureInput: Set<String>) async -> [BrowserLaunchPictures.Shot] {
        let deadline = ContinuousClock.now + pageCaptureDeadline
        let secureInput = secureInput.union(secureInputPages())
        var shots: [BrowserLaunchPictures.Shot] = []
        for pane in panes {
            if let shot = await launchPictureShot(pane.key, in: pane.host, secureInput: secureInput, deadline: deadline) { shots.append(shot) }
        }
        return shots
    }

    /// Tab `key`'s page as `host` shows it: nil for no engine page (none yet, deferred, asleep, a cmux page), one
    /// not on screen, or one that is withheld (``withholdsLaunchPicture(_:page:in:secureInput:)``).
    private func launchPictureShot(_ key: String, in host: NSView, secureInput: Set<String>,
                                   deadline: ContinuousClock.Instant) async -> BrowserLaunchPictures.Shot? {
        guard let page = browsers[key]?.tab, page is any BrowserFirstContentFrameReporting else { return nil }
        let view = page.contentView
        guard let window = view.window, VisiblePaneRefs.Window.isOnScreen(view), view.isDescendant(of: host),
              view.bounds.width > 0, view.bounds.height > 0,
              !withholdsLaunchPicture(key, page: page, in: window, secureInput: secureInput) else { return nil }
        // The geometry before the capture: the pane may change while it runs.
        let frame = view.convert(view.bounds, to: host), paneSize = host.bounds.size
        let top = host.isFlipped ? frame.minY : paneSize.height - frame.maxY
        guard let image = try? await ControlDeadline.shared.run(method: "launch-picture.capture", deadline: deadline, { @MainActor in
            try await page.snapshot()
        }) else { return nil }
        let picture = BrowserLaunchPictures.Picture(image: image, paneSize: paneSize,
                                                    pageFrame: CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height))
        return BrowserLaunchPictures.Shot(key: key, profile: page.profileID.rawValue, picture: picture)
    }

    /// The pages the windows' pictures fill for Secure Input: those that held it when the quit began (`quitBegan`,
    /// ``secureInputPages()`` then) and those that hold it now, since it may begin while the page captures run.
    func composeSecureInputPages(quitBegan: Set<String>) -> Set<String> {
        composeSecureInputPages(quitBegan: quitBegan, secureInput: IsSecureEventInputEnabled(), keyWindow: NSApp.keyWindow)
    }

    /// ``composeSecureInputPages(quitBegan:)`` with Secure Input on or off and `keyWindow` the app's key window (seams
    /// for tests).
    func composeSecureInputPages(quitBegan: Set<String>, secureInput: Bool, keyWindow: NSWindow?) -> Set<String> {
        quitBegan.union(secureInputPages(secureInput: secureInput, keyWindow: keyWindow))
    }

    /// What tab `key`'s browser page shows in its window's picture (`WindowPictureStore.Pane.Content(_:)` applies
    /// the fills): the picture the quit took of it, if any, and whether it is withheld now
    /// (``withholdsLaunchPicture(_:page:in:secureInput:)``; `secureInput` from ``composeSecureInputPages(quitBegan:)``).
    /// A page in no window is withheld. Nil when `key` has no page.
    func windowPictureSource(_ key: String, picture: BrowserLaunchPictures.Picture?, secureInput: Set<String>) -> WindowPictureStore.Pane.Source? {
        guard let page = browsers[key]?.tab else { return nil }
        let withheld = page.contentView.window.map { withholdsLaunchPicture(key, page: page, in: $0, secureInput: secureInput) } ?? true
        return .browserPage(page.contentView, picture: picture?.image, pageFrame: picture?.pageFrame ?? .zero, withheld: withheld)
    }

    /// Whether tab `key`'s page must leave no picture on disk (p08-startup 3C): an incognito page (an off-the-record
    /// profile or an incognito workspace), a page that holds Secure Input, a page with protected media, or a window
    /// hidden from screen capture (`NSWindow.sharingType == .none`).
    func withholdsLaunchPicture(_ key: String, page: any BrowserTab, in window: NSWindow, secureInput: Set<String>) -> Bool {
        if chromium.stores.offTheRecord.isOffTheRecord(page.profileID) || browserTabs.isIncognitoTab(key) { return true }
        if secureInput.contains(key) { return true }
        if let tab = tabModel(key), browserTabs.reopenedForProtectedMedia(tab) { return true }
        return window.sharingType == .none
    }
}
