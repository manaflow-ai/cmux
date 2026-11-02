import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextHome
import CmuxNextPages
import CmuxNextScreenshots
import CmuxNextTabs

/// One of this app's main windows as on screen, for `cmux window|pane|tab
/// screenshot`: the window server's image of the window and its Chromium
/// page windows (``NSWindow/screenshotImage(includeChild:)``: Ghostty's
/// Metal terminals and WebKit pages included, no Screen Recording grant,
/// background and covered windows too), then Chromium's own image of each
/// shown page painted over its page area (without the grant the window
/// server leaves out what Chromium's GPU process draws), then the overlay
/// panels, open menus and the app's other windows above the content. Nothing is focused, raised or
/// activated.
@MainActor
struct AppWindowImage {
    let services: AppServices

    /// The window's image at its backing scale, raw: only a person's own run in the app gets
    /// this (``ActionInvocation/isPersonsOwnRun``). An agent's or a script's run goes through
    /// ``maskedCapture(_:)``, which covers every page area and chat.
    /// - Throws: ``WindowScreenshotFailure`` when the window server gives no image.
    func capture(_ window: NSWindow) async throws -> CGImage {
        let base = try await window.screenshotImage(includeChild: WindowOverlayHost.isPageWindow)
        var layers: [WindowImageLayer] = []
        for (page, rect) in DebugWindowSnapshot.chromiumPages(in: window, services: services) {
            // A page that cannot give its image keeps the window server's
            // pixels there (its background without the grant).
            guard let image = try? await page.snapshot() else { continue }
            let holes = page.pageWindowHoles.map { page.contentView.convert($0, to: nil) }
            layers.append(.page(image, rect, holes: holes))
        }
        // React pages on the Chromium engine (the agent page, Settings) draw the same way.
        for (page, rect) in PageRegistry.shownChromiumPages(in: window) {
            guard let image = await page.chromiumImage() else { continue }
            layers.append(.page(image, rect, holes: page.chromiumWindowHoles)) // a chat leaves its pane's tabs uncovered
        }
        // The panel and floating-window captures run off the main actor too; main reads only their window numbers.
        if let panels = await window.childWindowsImage(includeChild: { !WindowOverlayHost.isPageWindow($0) }) {
            layers.append(.window(panels))
        }
        if let floating = await window.floatingWindowsImage() { layers.append(.window(floating.image)) }
        // The full-resolution redraw runs off the main actor.
        return await WindowImageLayer.compositedOffMain(base: base, windowSize: window.frame.size, layers: layers) ?? base
    }

    /// The window for an agent or a script, with every browser page and chat masked
    /// (``ScreenshotMask``): the window alone, without its child and floating windows (an
    /// overlay, hover card, drag ghost or menu can show a page) and without Chromium's browser
    /// pages (their pixels are only in their child windows), then the app's own Chromium pages
    /// painted in, then the masks on top. It fails closed: a mask that cannot be painted, or a
    /// window that keeps animating or resizing, refuses the capture instead of giving its pixels.
    /// - Returns: The image and how many areas it masks.
    /// - Throws: ``WindowScreenshotFailure`` or ``ScreenshotMask/Failure``.
    static func maskedCapture(_ window: NSWindow) async throws -> (image: CGImage, masked: Int) {
        for _ in 0..<ScreenshotMask.attempts {
            let sampler = ScreenshotMask.Sampler(window: window, rules: .app)
            defer { sampler.stop() }
            await ScreenshotMask.waitToSettle()
            let base = try await window.screenshotImage(includeChild: { _ in false })
            var layers: [WindowImageLayer] = []
            for (page, rect) in PageRegistry.shownChromiumPages(in: window) where !ScreenshotMask.isCovered(page, rules: .app) {
                guard let image = await page.chromiumImage() else { continue }
                layers.append(.page(image, rect, holes: page.chromiumWindowHoles)) // a chat leaves its pane's tabs uncovered
            }
            // The last reading follows the last await, so nothing changes before the paint.
            sampler.stop()
            let mask = sampler.mask
            guard mask.isSettled else { continue }
            layers += mask.regions.map(WindowImageLayer.mask)
            guard let image = WindowImageLayer.composite(base: base, window: window, layers: layers) else {
                if mask.regions.isEmpty { return (base, 0) }
                throw ScreenshotMask.Failure.unmaskable
            }
            return (image, mask.regions.count)
        }
        throw ScreenshotMask.Failure.unsettled
    }
}

extension ScreenshotMask.Rules {
    /// What an agent's or a script's capture of a window covers: every browser page area, every
    /// chat and conversation, and every app page not known to show nothing secret. A page's
    /// pixels reach automation only through the browser host's guarded capture (`cmux browser
    /// page screenshot`, which hides the secrets sessions typed), and a chat's text only through
    /// `cmux agents chat read`, which masks secrets; a window capture masks them whole. App pages
    /// are masked unless listed in ``ScreenshotMask/shownAppPages``, so a new page is masked
    /// until someone checks it.
    static let app = ScreenshotMask.Rules(
        covers: ScreenshotMask.covers,
        area: { view in
            // A browser pane whole, its toolbar and tab strip included: the address bar shows a
            // URL, which can carry a token or a one-time link, and the title and the badges come
            // from the page. #23983 masked the whole chrome and this keeps that. It is an `area`
            // rather than a `covers`, so `read` still descends and sees a page whose pixels have
            // moved out from under the mask. A pane hidden while the capture runs stays masked:
            // the mask is every reading's, and the screen lags the view tree by less than
            // ``ScreenshotMask/settle``, the wait between the first reading and the capture.
            if let chrome = view as? BrowserChromeView { return chrome }
            // PaneContentView keeps the tab strip beside the browser chrome. Tab titles, badges,
            // and page-derived labels in that sibling can carry the same secrets as the page.
            // Cover the strip as a separate area so window and pane crops cannot expose it.
            if let strip = view as? TabStripView { return strip }
            // A chat's last frame, drawn under the pane's content until its page paints. Hidden
            // it has already been replaced by the content above it, which `visit` reaches itself.
            guard let launch = (view as? PaneContentView)?.launchImageView, !launch.isHidden else { return nil }
            return launch
        },
        isAppPage: { $0 is PageWebView },
        coversContents: { $0 is BrowserChromeView }
    )
}

extension ScreenshotMask {
    /// The app pages a capture shows: they hold no secret, chat or browsing data, and nothing an
    /// agent cannot read another way (files, diffs, keys, the changelog). Every other app page
    /// (Settings with its key fields, Passwords, History, Home Channels, the agent page, Agent
    /// Activity's screen frames, the Chief's pages) is masked.
    static let shownAppPages: Set<String> = [
        "cmux.keybindings", "cmux.changelog", "cmux.icon-picker", "cmux.apps", "cmux.diff", "cmux.markdown", "cmux.editor",
        "cmux.files", "cmux.debug-settings",
    ]

    /// The native page tabs (``InternalPageView`` whose content is not a ``PageWebView``) a
    /// capture shows, by ``InternalPageID``: the same checked pages as ``shownAppPages``. Every
    /// other native page (Phone and Mac Screen frames, Passwords, History, Stashed, Inbox, Mobile
    /// Pairing's code, the Chief's pages, a new page) is masked whole until someone checks it.
    static let shownNativePages: Set<String> = [
        "keybindings", "changelog", "diff", "files", "files-pane", "find-pane", "markdown", "editor", "debug-settings",
    ]

    /// Whether a capture covers `view` whole: a browser tab's page, an agent chat, a Home
    /// conversation, list or draft, an app page not in ``shownAppPages`` or a native page tab
    /// not in ``shownNativePages``. Any other web view is
    /// covered unless a shown app page holds it (``ScreenshotMask/read(_:rules:)``).
    static func covers(_ view: NSView) -> Bool {
        if let page = view as? PageWebView { return !shownAppPages.contains(page.descriptor.id) }
        // A web page tab is judged by its PageWebView above; a native one by its page id here.
        if let tab = view as? InternalPageView, !(tab.content is PageWebView) { return !shownNativePages.contains(tab.page.rawValue) }
        return BrowserChromeView.isPageContent(view) || view is AgentPaneView || view is HomeHostView || view is TopHomePageView
            || view is HomeNewMessageView || view is HomeDockSwitchView || view is HomeSidebarView || view is HomeNativeTranscriptView
    }
}
