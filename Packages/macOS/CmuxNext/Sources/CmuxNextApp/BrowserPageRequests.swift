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

    func browserTab(_ page: any BrowserTab, didRequest intent: BrowserTabIntent) {
        guard let services, let key = services.cache.key(of: page), let (_, pane) = services.locateTab(key) else {
            // The opener is gone: nowhere to show a new page.
            if case .adoptTab(let child, _) = intent { child.close() }
            return
        }
        let engine = BrowserEngineResolver.tag(for: page.engineKind).rawValue
        switch intent {
        case .openURL(let url, let disposition):
            open(url: url, adopting: nil, engine: engine, in: pane, background: disposition == .backgroundTab)
        case .adoptTab(let child, let disposition):
            open(url: child.state.url, adopting: child, engine: engine, in: pane, background: disposition == .backgroundTab)
        case .close:
            services.registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key)))
        case .activate:
            services.paneController(for: pane)?.select(StripTabID(key), source: .intent)
        case .contextMenu(let request):
            let target = ActionTargetRef(kind: .tab, id: key)
            let host = services.registry.makeContextMenu(for: .browserPage, target: target,
                                                         entries: ContextMenuCatalog.browserPageAfterEngineMenu,
                                                         implied: .browserFocused)
            let extra = host.items
            host.removeAllItems()
            BrowserContextMenuBuilder.present(request, in: page.contentView, extra: extra)
        case .download:
            break
        }
    }

    private func open(url: URL?, adopting child: (any BrowserTab)?, engine: String, in pane: PaneModel, background: Bool) {
        guard let services else { child?.close(); return }
        if let controller = services.paneController(for: pane) {
            return controller.newBrowserTab(url: url, inherited: engine, adopting: child, background: background)
        }
        // The opener's pane is not on screen (its page is kept alive).
        let browserTabs = services.cache.browserTabs!
        guard browserTabs.isAvailable() else { child?.close(); return }
        let choice = Self.choice(adopting: child, inherited: engine, browserTabs: browserTabs)
        let handle = pane.handle, address = url?.absoluteString ?? "about:blank"
        services.registry.track(Task { [weak self] in
            do {
                let surface = try await browserTabs.open(choice, in: handle, url: address)
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
        if let tab = services.locateTab(surface: surface), services.cache.existingBrowser(tab.id) != nil {
            services.cache.replacePage(of: tab, with: page)
        } else {
            adoptions[surface] = page
        }
    }

    func takeAdoption(for surface: SurfaceID) -> (any BrowserTab)? {
        adoptions.removeValue(forKey: surface)
    }
}
