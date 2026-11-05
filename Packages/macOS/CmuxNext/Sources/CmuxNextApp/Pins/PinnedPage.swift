import CmuxNextActions
import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// Back to Pinned Page (cx-lle.6, Chrome's pinned tabs): a pinned browser
/// tab keeps the page it was pinned on (the daemon records it at pin time,
/// `pinned_url`). `browser.resetPinnedTab` takes the tab back there from the
/// tab menu, the palette, `cmux browser back-to-pinned-page` and MCP; a
/// pinned tab of this Mac restored at launch opens there too (`restoreURL`).
@MainActor
enum PinnedPage {
    static func bind(_ registry: ActionRegistry, ctx: AppActionContext) {
        registry.bind("browser.resetPinnedTab", invoke: { reset(ctx, $0) })
        // The tab menu shows it only where it does something: a pinned
        // browser tab away from its pinned page. An unresolved target keeps
        // the row (its handler reports why).
        ActionTargetVisibility.hide("browser.resetPinnedTab", in: registry) { invocation in
            guard let id = invocation.target?.id, let (tab, _) = ctx.targetTab(id, invocation) else { return false }
            return target(of: tab, ctx).map { $0.absoluteString == tab.url } ?? true
        }
    }

    /// The page `tab` was pinned on; nil unless it is a pinned browser tab
    /// whose daemon recorded one. An incognito tab's record is a placeholder,
    /// never its page.
    static func page(of tab: TabModel) -> URL? {
        guard tab.kind == .browser, tab.pinned, let raw = tab.pinnedURL,
              raw != BrowserTabService.incognitoPlaceholderURL else { return nil }
        return URL(string: raw)
    }

    /// A remote machine's pinned page: only a web page opens here (`RemoteRelayPolicy`).
    static func remotePage(of tab: TabModel) -> URL? {
        page(of: tab).flatMap { RemoteRelayPolicy.remoteBrowserURL($0.absoluteString) }
    }

    /// Where a restored pinned tab of this Mac opens (a page from an earlier
    /// launch): its pinned page. A tab opened in this launch keeps its record's URL.
    static func restoreURL(_ tab: TabModel, openedHere: Bool) -> String? {
        openedHere ? nil : page(of: tab)?.absoluteString
    }

    /// Where Back to Pinned Page takes `tab`: its pinned page (a remote
    /// machine's only when it opens here); nil for an incognito tab.
    private static func target(of tab: TabModel, _ ctx: AppActionContext) -> URL? {
        guard !ctx.services.cache.browserTabs.isIncognitoTab(tab.id) else { return nil }
        return ctx.services.machines.daemon(forTab: tab).isLocal ? page(of: tab) : remotePage(of: tab)
    }

    private static func reset(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let (tab, _) = ctx.daemonTab(invocation) else { return }
        let daemon = ctx.services.machines.daemon(forTab: tab)
        guard let page = target(of: tab, ctx) else { return ctx.refuse(PinStrings.noPinnedPage) }
        // A loaded page goes there (its record follows); a page not loaded
        // here yet opens there, from its record.
        if let entry = ctx.services.cache.existingBrowser(tab.id) {
            entry.tab.load(page)
            return
        }
        let surface = tab.surface, url = page.absoluteString
        daemon.send("update-frontend-browser-tab") { _ = try await $0.updateFrontendBrowserTab(surface, url: url) }
    }
}
