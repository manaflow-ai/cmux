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
            guard let id = invocation.target?.id, let (tab, _) = ctx.services.locateTab(id) else { return false }
            return page(of: tab).map { $0.absoluteString == tab.url } ?? true
        }
    }

    /// The page `tab` was pinned on; nil unless it is a pinned browser tab
    /// whose daemon recorded one.
    static func page(of tab: TabModel) -> URL? {
        guard tab.kind == .browser, tab.pinned, let raw = tab.pinnedURL else { return nil }
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

    private static func reset(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let (tab, _) = ctx.daemonTab(invocation) else { return }
        let daemon = ctx.services.machines.daemon(forTab: tab)
        guard let page = daemon.isLocal ? page(of: tab) : remotePage(of: tab) else { return ctx.refuse(PinStrings.noPinnedPage) }
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
