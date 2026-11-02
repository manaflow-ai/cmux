import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextMacScreen
import CmuxNextNowPlaying
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextRemoteLocalhostService

/// Tabs a page asks for: a link opened in a new tab (Cmd-click, middle
/// click, `target=_blank` handled as a URL), a popup or `window.open` that
/// needs its opener (the engine already created the page), and
/// `window.close()`, an extension selecting a tab (`chrome.tabs.update`),
/// and the page context menu (the cmux link, image and selection rows of
/// both engines, `BrowserHitMenu`; then Chromium's remaining items,
/// extension `chrome.contextMenus` included, and the cmux page actions).
/// New tabs land in the opener's pane on the opener's
/// engine: `window.opener` and the page's cookies live in one engine, and
/// the opener is Chromium unless someone chose WebKit. They go next to the
/// opener in Chrome's order (`openers`).
final class BrowserPageRequests: BrowserTabDelegate {
    weak var services: AppServices? {
        didSet {
            nowPlaying.follow(services)
            sidebarNowPlaying.follow(sessions: { [weak self] in self?.services.map { s in s.cache.pageRequests.media.sessions(in: s.cache).map { NowPlayingSession(tab: $0.entry.tab.id, media: $0.media) } } ?? [] },
                                     tab: { [weak self] id in self?.services?.cache.browsers.values.first { $0.tab.id == id }?.tab })
            sidebarNowPlaying.allowsPictureInPicture = { [weak self] in PictureInPictureHandlers.isEnabled(self?.services) }
            // A popup panel's page gets the same rows, acting for its opener's tab.
            services?.popups.hitItems = { [weak self] target, openerKey in self?.hitItems(for: target, tab: openerKey) ?? [] }
            // A popup window's omnibar suggests from its page's profile, as a tab's does.
            services?.popups.suggestionEngine = { [weak self] page in self?.services?.cache.suggestionEngine(forPage: page) }
            // A reopened tab restores one history, not two (cx-d0d.11).
            services?.cache.browserTabs.restoredInMemory = { [weak self] tab, engine in self?.closedHistories.takeRestored(tab, engine: engine) ?? false }
            // The Downloads list a relaunch shows keeps ended downloads (cx-d0d.72).
            if services != nil, downloads.history == nil {
                downloads.history = BrowserDownloadHistory.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
                // task-owner: one read at startup; the list holds nothing it could race with but this run's rows
                Task { [downloads] in await downloads.restore() }
            }
            // A tab an agent-driven page opens is agent-driven from birth,
            // marked before its page exists (no rebuild on the agent's first
            // touch, no saved password filled), as its adopted pages are.
            openers.inheritsFromOpener = { [weak self] child, opener in
                guard let services = self?.services, let tab = services.locateTab(surface: opener),
                      services.cache.agentDrivenTabs.contains(tab.id) else { return }
                services.cache.markAgentDriven(surface: child)
                if let key = services.locateTab(surface: child)?.id, services.cache.existingBrowser(key) != nil {
                    services.cache.markAgentDriven(key)
                }
            }
        }
    }
    /// Every download of both engines, with a notice when one ends.
    let downloads = BrowserDownloadList()
    /// Every tab's media, for the toolbar's media hub.
    let media = BrowserMediaHub()
    /// The playing tab in macOS Now Playing and on the media keys.
    let nowPlaying = BrowserNowPlaying()
    /// The playing tab for the sidebar's Now Playing card (cx-ouoxo).
    let sidebarNowPlaying = BrowserTabsNowPlaying()
    /// cmux's own music player (cx-imt2i, a preview feature).
    let music = MusicPlayer()
    /// What the Now Playing card shows and drives: the player while it plays, else the playing tab,
    /// else another app that plays (Spotify, Music: macOS Now Playing, cmux's own entries left out)
    /// while `sidebar.nowPlaying.otherApps` is on (off by default: only what plays in cmux).
    private(set) lazy var sidebarSources = NowPlayingSources(
        player: music, tabs: sidebarNowPlaying, system: SystemNowPlaying.bundled(),
        otherApps: { [weak self] in self?.services?.settings?.snapshot.nowPlaying.otherApps ?? NowPlayingSettings.otherAppsDefault })
    /// Whether the Now Playing card is put away (its x, Hide, Hide Until Relaunch; u2437), for every window's sidebar.
    let nowPlayingCard = NowPlayingCardDismissal()
    /// Where a page's new tab goes next to its opener.
    let openers = BrowserTabOpeners()
    /// Background tabs whose title changed (the strip's unread dot).
    let titleAttention = BrowserTitleAttention()
    /// Closed tabs' histories, for Reopen Closed Tab.
    let closedHistories = ClosedBrowserHistories()
    /// Pages created by an engine for a daemon tab that is still being
    /// created, by the new tab's surface. `TabContentCache` takes them.
    private var adoptions: [SurfaceID: any BrowserTab] = [:]
    /// Adopted pages that closed before their daemon tab existed (an
    /// extension's chrome.tabs.remove right after chrome.tabs.create).
    /// Weak: a page closed by its user (already uninstalled) lands here too
    /// and must not be kept alive.
    private var closedBeforeAdoption: [WeakPage] = []
    /// Daemon tabs to close when they appear: their page closed first.
    private var closeOnArrival: Set<SurfaceID> = []
    /// Tabs whose Chromium store is a Cloud machine's proxy (`browser.tab.open`).
    let proxiedTabs = ProxiedBrowserTabs()

    /// Site settings of `site`, a site whose automatic-downloads setting
    /// blocked a download in tab `tab` (its profile's store). One path for
    /// the notice's button and `browser.download.openBlockedSiteSettings`.
    @discardableResult
    func openBlockedSiteSettings(site: String, tab: String) -> Bool {
        guard let chrome = services?.cache.existingBrowser(tab)?.chrome else { return false }
        chrome.pageInfo.showSiteSettings(origin: site)
        return true
    }

    /// Whether the newest blocked download's tab is still open.
    var canOpenLatestBlockedSiteSettings: Bool {
        downloads.latestBlocked.flatMap { services?.cache.existingBrowser($0.tab) } != nil
    }

    func browserTab(_ page: any BrowserTab, didRequest intent: BrowserTabIntent) {
        // A popup panel's page: the panel handles it (window.close closes
        // the panel), except links it opens in tabs (its opener's pane).
        if let services, services.popups.handle(page, intent) { return }
        if case .close = intent, let services, services.cache.key(of: page) == nil {
            // Not installed yet: its daemon tab is still being created.
            return pageClosedBeforeAdoption(page)
        }
        guard let services, let key = services.cache.key(of: page) ?? services.popups.openerKey(of: page),
              let (openerTab, pane) = services.locateTabOnAnyMachine(key) else {
            // The opener is gone: nowhere to show a new page.
            switch intent {
            case .adoptTab(let child, _), .openPopup(let child, _): child.close()
            default: break
            }
            return
        }
        // A page an agent drives passes that on to the pages it makes (an
        // OAuth popup must not get a saved password filled either).
        if services.cache.agentDrivenTabs.contains(key) {
            switch intent {
            case .adoptTab(let child, _), .openPopup(let child, _): child.markAgentDriven()
            default: break
            }
        }
        // Chromium's password manager asked for as a new tab (an omnibar
        // modified commit) is cmux's Passwords page (ChromiumPageRoute). A tab
        // Chromium makes itself (`.adoptTab`) has no URL yet here.
        if case .openURL(let url, let disposition) = intent, ChromiumPageRoute(url) == .passwordsPage {
            try? ChromiumPageRouter.showPasswords(services, focus: disposition != .backgroundTab)
            return
        }
        let engine = page.engineKind.daemonEngine.rawValue
        // A page's new tabs stay in its browser profile (its cookies, and the
        // store an engine-made child page already uses).
        let profile = services.cache.tabModel(key).map(services.browserProfiles.profileID(ofTab:))
        switch intent {
        case .openURL(let url, .newWindow):
            openInNewWorkspace(url, opener: page)
        case .adoptTab(let child, .newWindow):
            openInNewWorkspace(child.state.url, adopting: child, opener: page)
        case .openURL(let url, .linkPlacement):
            openOnRight(url: url, adopting: nil, engine: engine, profile: profile, from: pane, opener: openerTab.surface)
        case .adoptTab(let child, .linkPlacement):
            openOnRight(url: child.state.url, adopting: child, engine: engine, profile: profile, from: pane, opener: openerTab.surface)
        case .openURL(let url, let disposition):
            open(url: url, adopting: nil, engine: engine, profile: profile, in: pane, opener: openerTab.surface,
                 background: disposition == .backgroundTab)
        case .adoptTab(let child, let disposition):
            open(url: child.state.url, adopting: child, engine: engine, profile: profile, in: pane, opener: openerTab.surface,
                 background: disposition == .backgroundTab)
        case .close:
            services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key)))
        case .activate:
            services.paneController(for: pane)?.select(StripTabID(key), source: .intent)
        case .contextMenu(let request):
            let leading = hitItems(for: request.target, tab: key)
            // WebKit shows its own menu: the rows go into it.
            if let insert = request.insertLeading { return insert(leading) }
            let target = ActionTargetRef(kind: .tab, id: key)
            let host = services.registry.makeContextMenu(for: .browserPage, target: target,
                                                         entries: services.registry.browserPageAfterEngineMenu,
                                                         implied: .browserFocused)
            let extra = BrowserProfileLinkMenu.items(for: request.target.linkURL, target: ActionTargetRef(kind: .pane, id: pane.id),
                                                     services: services) + host.items + PageShareMenu.items(for: page.state.url)
            host.removeAllItems()
            // The engine's menu holds the page rows: Customize Menu… ends it as it ends every whole menu.
            // The engine's menu puts a separator before the extra rows; one more only after rows of ours.
            let customize = services.registry.customizeMenuItem(for: .browserPage).map { extra.isEmpty ? [$0] : [NSMenuItem.separator(), $0] } ?? []
            services.contextMenus.present(request, in: page.contentView, leading: leading, extra: extra + customize)
        case .notice(let text):
            services.cache.existingBrowser(key)?.chrome.showNotice(text)
        case .download(let item):
            downloads.add(item, tab: key, keep: !services.cache.browserTabs.isIncognitoTab(key)) { [weak services] notice in
                guard let services, let entry = services.cache.existingBrowser(key) else { return }
                // A finished download opens the Downloads popup under the tab's
                // button, as Chrome's bubble does; the notice is for a tab not on screen.
                if notice.finished, BrowserToolbarHandlers.showDownloads(for: entry, services: services, finished: true) { return }
                let chrome = entry.chrome
                // A blocked download offers the blocking site's Site
                // settings, where its automatic-downloads choice changes
                // (the same path as browser.download.openBlockedSiteSettings).
                let action = notice.siteSettingsOrigin.map { origin -> (title: String, run: () -> Void) in
                    (title: BrowserHitStrings.siteSettings, run: { [weak self] () -> Void in _ = self?.openBlockedSiteSettings(site: origin, tab: key) })
                }
                chrome.showNotice(notice.text, action: action)
            }
        case .rerouteStore(let url):
            services.cache.reroute(key, to: url)
        case .openLocalFile(let url):
            // A page's navigation is not the user choosing the file: it shows
            // read only outside the roots the user chose.
            if let reason = services.viewers.openFile(url, in: services.paneController(for: pane), userChose: false) {
                services.cache.existingBrowser(key)?.chrome.showNotice(reason)
            }
        case .openPopup(let child, let request):
            openPopup(child, request: request, openerKey: key, pane: pane)
        case .unhandledKey(let pageKey):
            services.keyRouter.routePageKey(pageKey, from: page)
        case .webNotification(let notification):
            services.notifications.postWebNotification(notification, surface: openerTab.surface)
        case .verificationPageWaiting:
            services.verificationAutofill.pageWaiting(page)
        case .designMode(let message):
            services.designMode.receive(message, from: page)
        case .protectedMediaUnavailable(let media):
            reopenInWebKit(page, for: media, tab: openerTab, pane: pane)
        case .unhandledEscape, .resizePopup:
            break
        case .takeFocus:
            services.focusAddressBarAfterPage(key)
        }
    }

    /// A Chromium tab whose page was refused protected media (Widevine) reopens
    /// in WebKit at the same address, right after it, once, with a note; the
    /// Chromium tab closes. A tab whose engine someone asked for stays.
    private func reopenInWebKit(_ page: any BrowserTab, for media: BrowserProtectedMedia, tab: TabModel, pane: PaneModel) {
        guard let services else { return }
        let browserTabs = services.cache.browserTabs
        guard media.reopensInWebKit(engineIsChromium: page.engineKind == .cef, enginePinned: browserTabs.isEnginePinned(tab),
                                    alreadyReopened: browserTabs.reopenedForProtectedMedia(tab)),
              let url = page.state.url, let controller = services.paneController(for: pane) else { return }
        browserTabs.noteProtectedMediaReopen(tab)
        let key = tab.id
        let profile = services.browserProfiles.profileID(ofTab: tab)
        controller.newBrowserTab(url: url, engine: BrowserEngineTag.webkit.rawValue, profile: profile,
                                 notice: BrowserProtectedMedia.reopenedNotice, opener: tab.surface) { [weak services] _ in
            services?.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key), origin: .script)) // replaced: never asks
        }
    }

    /// The link, image and selection rows for a right-click on the page of
    /// tab `key`.
    func hitItems(for target: BrowserContextMenuTarget, tab key: String) -> [NSMenuItem] {
        guard let services else { return [] }
        return BrowserHitMenu.items(for: target, tab: ActionTargetRef(kind: .tab, id: key), registry: services.registry,
                                    searchEngine: services.cache.suggestionEngine.resolver.searchEngine.name)
    }

    /// Routes `chrome`'s modified omnibar commits to ``openFromOmnibar``;
    /// a typed commit in the tab itself ends link-tab opener relations
    /// (``BrowserTabOpeners/typedNavigation(onNewTabPageAtEnd:)``).
    func routeOmnibarOpens(of chrome: BrowserChromeView, page: any BrowserTab) {
        chrome.onOpenURL = { [weak self, weak page] url, disposition in
            guard let page else { return }
            self?.openFromOmnibar(url, disposition, page: page)
        }
        chrome.onTypedCommit = { [weak self, weak page] in
            guard let self, let page else { return }
            openers.typedNavigation(onNewTabPageAtEnd: isNewTabPageAtEnd(page))
        }
    }

    /// `page` shows a New Tab page and is the last tab of its pane.
    private func isNewTabPageAtEnd(_ page: any BrowserTab) -> Bool {
        guard BrowserNewTabPage.isNewTabPage(page.state.url), let services, let key = services.cache.key(of: page),
              let (_, pane) = services.locateTabOnAnyMachine(key) else { return false }
        return pane.tabs.last?.id == key
    }

    /// The omnibar's modified commit (Cmd-Return, Shift-Cmd-Return,
    /// Option-Return, Shift-Return, a modified suggestion click) takes the
    /// same path as the page's own links: the opener's pane, engine and
    /// browser profile. Shift-Return opens a new window with a new
    /// workspace that holds the tab (cmux windows hold workspaces).
    func openFromOmnibar(_ url: URL, _ disposition: OmnibarDisposition, page: any BrowserTab) {
        // A pairing link (or a search for one) never loads anywhere: Mac Screen says why.
        if let refusal = MacScreenPages.pairingLinkRefusal(for: url.absoluteString) {
            services?.registry.refuse(refusal)
            return
        }
        switch disposition {
        case .currentTab:
            // The host's own pages and routed chrome:// pages, as a plain Return does.
            if let key = services?.cache.key(of: page), services?.cache.existingBrowser(key)?.chrome.loadOverride?(url) == true { return }
            page.load(url)
        case .newBackgroundTab: browserTab(page, didRequest: .openURL(url, .backgroundTab))
        case .newForegroundTab: browserTab(page, didRequest: .openURL(url, .foregroundTab))
        case .newWindow: browserTab(page, didRequest: .openURL(url, .newWindow))
        }
    }

    /// `url` (or `child`, a page the engine already made) in a new
    /// workspace that holds one browser tab on the opener's engine and
    /// browser profile: in a new window, else in `window` (the active one
    /// when nil), pinned to `room` when given. An incognito opener, or one
    /// on another machine, opens a foreground tab next to it instead: the
    /// new workspace would leave its profile or its machine.
    func openInNewWorkspace(_ url: URL?, adopting child: (any BrowserTab)? = nil, opener page: any BrowserTab,
                            newWindow: Bool = true, window: String? = nil, room: ProfileID? = nil) {
        guard let services, let key = services.cache.key(of: page), let tab = services.cache.tabModel(key) else {
            child?.close()
            return
        }
        let browserTabs = services.cache.browserTabs
        let daemon = services.machines.daemon(forTab: tab)
        guard browserTabs.isAvailable(on: daemon), daemon === services.activeDaemon, !browserTabs.isIncognitoTab(key) else {
            if let child { return browserTab(page, didRequest: .adoptTab(child, .foregroundTab)) }
            if let url { browserTab(page, didRequest: .openURL(url, .foregroundTab)) }
            return
        }
        let engine = page.engineKind.daemonEngine.rawValue
        let choice = Self.choice(adopting: child, inherited: engine, browserTabs: browserTabs)
        let profile = services.browserProfiles.profileID(ofTab: tab)
        let address = child == nil ? (url?.absoluteString ?? "about:blank") : BrowserNewTabPage.blankURL
        WorkspaceHandlers.createAndShow(services: services, newWindow: newWindow, window: window, room: room) { [weak self] connection, terminal in
            guard let pane = terminal.pane else { return }
            let surface = try await browserTabs.open(choice, in: pane, on: daemon, url: address, profile: profile)
            if let child { await self?.adopt(child, surface: surface) }
            if let terminal = terminal.surface { try await connection.closeTab(terminal) }
        }
    }

    /// A sized popup opens in a popup window of its own, placed from the
    /// window that shows its opener (else the active window); it is never a
    /// daemon tab.
    private func openPopup(_ child: any BrowserTab, request: BrowserPopupRequest, openerKey: String, pane: PaneModel) {
        guard let services else { child.close(); return }
        let owner = services.windows.controllers.first { $0.content?.pane(for: pane.handle) != nil }
        guard let window = (owner ?? services.windows.active)?.window else {
            child.close()
            return
        }
        services.popups.open(child, request: request, from: window, openerKey: openerKey)
    }

    /// A Cmd-click (`browser.links.cmdClick`: `linkPlacement`): the same placement as every other
    /// link the person opens (``LinkOpener``, `layout.linkPlacement`): the pane right of the page's
    /// pane, else a new split there; the page keeps showing. The opener's engine and browser profile
    /// carry over, and an engine-made child page is adopted there (`window.opener` kept). With its
    /// pane off screen it opens as a background tab next to the opener, as before.
    private func openOnRight(url: URL?, adopting child: (any BrowserTab)?, engine: String, profile: String?, from pane: PaneModel,
                             opener: SurfaceID) {
        guard let services, let source = services.paneController(for: pane) else {
            return open(url: url, adopting: child, engine: engine, profile: profile, in: pane, opener: opener, background: true)
        }
        // A refusal closes an adopted child itself (PaneBrowserTabOpener).
        services.linkOpener.open(from: source, kind: .browser) { target, placed in
            target.newBrowserTab(url: url, inherited: engine, adopting: child, background: placed != nil, profile: profile,
                                 opener: target === source ? opener : nil, then: placed)
        }
    }

    private func open(url: URL?, adopting child: (any BrowserTab)?, engine: String, profile: String?, in pane: PaneModel,
                      opener: SurfaceID, background: Bool) {
        guard let services else { child?.close(); return }
        if let controller = services.paneController(for: pane) {
            controller.newBrowserTab(url: url, inherited: engine, adopting: child, background: background, profile: profile,
                                     opener: opener)
            return
        }
        // The opener's pane is not on screen (its page is kept alive).
        let browserTabs = services.cache.browserTabs
        guard browserTabs.isAvailable(in: pane) else { child?.close(); return }
        let choice = Self.choice(adopting: child, inherited: engine, browserTabs: browserTabs)
        let address = url?.absoluteString ?? "about:blank", openers = openers
        services.registry.track(Task { [weak self] in
            do {
                let surface = try await openers.open(opener, foreground: !background, in: pane, browserTabs: browserTabs) { after in
                    try await browserTabs.open(choice, in: pane, url: address, profile: profile, activate: !background, after: after)
                }
                if let child { self?.adopt(child, surface: surface) }
                return nil
            } catch {
                child?.close()
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// The engine for a page-requested tab: the child's own engine when the
    /// engine already made the page, else the opener's (with the fallback).
    static func choice(adopting child: (any BrowserTab)?, inherited: String?, browserTabs: BrowserTabService) -> BrowserEngineChoice {
        if let child { return BrowserEngineChoice(engine: child.engineKind.daemonEngine, inherited: true) }
        if case .open(let choice) = browserTabs.resolve(requested: nil, inherited: inherited) { return choice }
        return BrowserEngineChoice(engine: .webkit)
    }

    /// `page` belongs to the daemon tab on `surface`. When that tab's page
    /// was already created (the tree arrived before the create reply), the
    /// adopted page replaces it.
    func adopt(_ page: any BrowserTab, surface: SurfaceID) {
        guard let services else { page.close(); return }
        if let index = closedBeforeAdoption.firstIndex(where: { $0.page === page }) {
            // The page closed while its tab was created: no ghost tab.
            closedBeforeAdoption.remove(at: index)
            return closeDaemonTab(on: surface)
        }
        if let tab = services.locateTab(surface: surface), services.cache.existingBrowser(tab.id) != nil {
            services.cache.replacePage(of: tab, with: page)
        } else {
            adoptions[surface] = page
        }
    }

    /// The page made for daemon tab `tab` before it appeared, else a
    /// restored WebKit page for a reopened tab with a saved history (cx-d0d.59).
    func takeAdoption(for tab: TabModel) -> (any BrowserTab)? {
        if let page = adoptions.removeValue(forKey: tab.surface) { return page }
        guard tab.browserEngine != BrowserEngineTag.cef.rawValue, let services, services.machines.daemon(forTab: tab).isLocal,
              !proxiedTabs.isProxied(tab.id) else { return nil }
        let cache = services.cache, profile = cache.browserProfile?(tab.id) ?? .default
        guard let state = closedHistories.claim(tab.url, profile: profile, chromium: false, tab: tab.id) else { return nil }
        let page = cache.webKit.makeWebKitTab(profile: profile)
        if !page.restore(state), let url = tab.url.flatMap(URL.init(string:)) { page.load(url) }
        return page
    }

    /// True once for a daemon tab whose page closed before it appeared; the
    /// caller shows nothing for it and ``closeTab(_:)`` removes it.
    func claimCloseOnArrival(_ surface: SurfaceID) -> Bool {
        closeOnArrival.remove(surface) != nil
    }

    func closeTab(_ key: String) {
        services?.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key)))
    }

    private func pageClosedBeforeAdoption(_ page: any BrowserTab) {
        if let surface = adoptions.first(where: { $0.value === page })?.key {
            adoptions[surface] = nil
            closeDaemonTab(on: surface)
        } else {
            closedBeforeAdoption.removeAll { $0.page == nil || $0.page === page }
            closedBeforeAdoption.append(WeakPage(page: page))
        }
    }

    private func closeDaemonTab(on surface: SurfaceID) {
        if let tab = services?.locateTab(surface: surface) {
            closeTab(tab.id)
        } else {
            closeOnArrival.insert(surface)
        }
    }
}

/// A page reference that does not keep the page alive.
struct WeakPage {
    weak var page: (any BrowserTab)?
}
