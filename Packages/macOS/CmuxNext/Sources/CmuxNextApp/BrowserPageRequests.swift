import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs

/// Tabs a page asks for: a link opened in a new tab (Cmd-click, middle
/// click, `target=_blank` handled as a URL), a popup or `window.open` that
/// needs its opener (the engine already created the page), and
/// `window.close()`, an extension selecting a tab (`chrome.tabs.update`),
/// and the page context menu (Chromium's items, extension
/// `chrome.contextMenus` included, then the cmux browser-page actions).
/// New tabs land in the opener's pane on the opener's
/// engine: `window.opener` and the page's cookies live in one engine, and
/// the opener is Chromium unless someone chose WebKit.
final class BrowserPageRequests: BrowserTabDelegate {
    weak var services: AppServices?
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

    func browserTab(_ page: any BrowserTab, didRequest intent: BrowserTabIntent) {
        // A popup panel's page: the panel handles it (window.close closes
        // the panel), except links it opens in tabs (its opener's pane).
        if let services, services.popups.handle(page, intent) { return }
        if case .close = intent, let services, services.cache.key(of: page) == nil {
            // Not installed yet: its daemon tab is still being created.
            return pageClosedBeforeAdoption(page)
        }
        guard let services, let key = services.cache.key(of: page) ?? services.popups.openerKey(of: page),
              let (_, pane) = services.locateTab(key) else {
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
        let engine = BrowserEngineResolver.tag(for: page.engineKind).rawValue
        // A page's new tabs stay in its browser profile (its cookies, and the
        // store an engine-made child page already uses).
        let profile = services.cache.tabModel(key).map(services.browserProfiles.profileID(ofTab:))
        switch intent {
        case .openURL(let url, let disposition):
            open(url: url, adopting: nil, engine: engine, profile: profile, in: pane, background: disposition == .backgroundTab)
        case .adoptTab(let child, let disposition):
            open(url: child.state.url, adopting: child, engine: engine, profile: profile, in: pane, background: disposition == .backgroundTab)
        case .close:
            services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key)))
        case .activate:
            services.paneController(for: pane)?.select(StripTabID(key), source: .intent)
        case .contextMenu(let request):
            let target = ActionTargetRef(kind: .tab, id: key)
            let host = services.registry.makeContextMenu(for: .browserPage, target: target,
                                                         entries: ContextMenuCatalog.shared.browserPageAfterEngineMenu,
                                                         implied: .browserFocused)
            let extra = BrowserProfileLinkMenu.items(for: request.target.linkURL, target: ActionTargetRef(kind: .pane, id: pane.id),
                                                     services: services) + host.items
            host.removeAllItems()
            services.contextMenus.present(request, in: page.contentView, extra: extra)
        case .notice(let text):
            services.cache.existingBrowser(key)?.chrome.showNotice(text)
        case .download:
            break
        case .rerouteStore(let url):
            services.cache.reroute(key, to: url)
        case .openPopup(let child, let request):
            openPopup(child, request: request, openerKey: key, pane: pane)
        case .unhandledEscape, .resizePopup:
            break
        case .takeFocus:
            services.focusAddressBarAfterPage(key)
        }
    }

    /// A sized popup opens in a floating panel over the window that shows
    /// its opener (else the active window); it is never a daemon tab.
    private func openPopup(_ child: any BrowserTab, request: BrowserPopupRequest, openerKey: String, pane: PaneModel) {
        guard let services else { child.close(); return }
        let owner = services.windows.controllers.first { $0.content?.pane(for: pane.handle) != nil }
        guard let window = (owner ?? services.windows.active)?.window else {
            child.close()
            return
        }
        services.popups.open(child, request: request, over: window, openerKey: openerKey)
    }

    private func open(url: URL?, adopting child: (any BrowserTab)?, engine: String, profile: String?, in pane: PaneModel, background: Bool) {
        guard let services else { child?.close(); return }
        if let controller = services.paneController(for: pane) {
            return controller.newBrowserTab(url: url, inherited: engine, adopting: child, background: background, profile: profile)
        }
        // The opener's pane is not on screen (its page is kept alive).
        let browserTabs = services.cache.browserTabs!
        guard browserTabs.isAvailable() else { child?.close(); return }
        let choice = Self.choice(adopting: child, inherited: engine, browserTabs: browserTabs)
        let handle = pane.handle, address = url?.absoluteString ?? "about:blank"
        services.registry.track(Task { [weak self] in
            do {
                let surface = try await browserTabs.open(choice, in: handle, url: address, profile: profile)
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
        if let child { return BrowserEngineChoice(engine: BrowserEngineResolver.tag(for: child.engineKind), inherited: true) }
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

    func takeAdoption(for surface: SurfaceID) -> (any BrowserTab)? {
        adoptions.removeValue(forKey: surface)
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
