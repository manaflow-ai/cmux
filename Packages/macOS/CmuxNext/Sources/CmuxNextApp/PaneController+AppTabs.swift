import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDiff
import CmuxNextPages
import CmuxNextPullRequestDiff
import CmuxNextWakeups
import Foundation

extension PaneController {
    /// An app tab (`app-screens-v1`): the app's own page, mounted through the
    /// app supervisor, as a store page tab. Nil while the app has no page here
    /// (not installed, hidden, or the supervisor is unreachable).
    func appTabContent(_ tab: TabModel) -> TabContent? {
        guard let app = tab.appTab,
              let provider = services.apps.pageProvider(appID: app.app, codeRouterAsPage: false) else { return nil }
        return services.pages.view(forStoreTab: tab, page: provider.page, in: daemon.store,
                                   window: state.flatMap { services.windows.controller(for: $0.id) })
            .map(TabContent.page)
    }

    /// A tab of the GitHub page cmux no longer has (removed in cmux#37219; Leo, 2026-11-06: "stop doing
    /// our own renderer for this"), restored from a session saved before. It shows its pull request's
    /// github.com page in place at once, so it is never blank. Once per run, the same page also opens as
    /// a real browser tab in this pane, and the old tab closes only when the daemon made that tab; a
    /// refused, failed or local-only open leaves the old tab showing the page. Nil for a route with no
    /// pull request.
    func retiredGitHubTabContent(_ tab: TabModel) -> TabContent? {
        guard let url = GitHubLink(pageRoute: tab.pageRoute)?.url else { return nil }
        if services.pages.retiringTabs.insert(tab.id).inserted {
            let id = tab.id, surface = tab.surface
            // After the frame: the show that asked for this tab's content never opens or closes tabs in its turn.
            AfterFrameCommit().run { [weak self] in
                _ = self?.newBrowserTab(url: url, opener: surface) { [weak self] _ in self?.close([StripTabID(id)]) }
            }
        }
        return .browser(services.cache.browser(for: tab.id, url: url))
    }
}

/// A pull request's Files tab link (`/pull/N/files`, Session Info's View diff) opens its diff beside
/// the chat (``PullRequestDiff``). Every other github.com link, a pull request's own page included,
/// opens github.com in the browser (Leo, 2026-11-06: "stop doing our own renderer for this").
extension PullRequestDiff {
    /// True when `url` is a Files tab link the link rule sends to a cmux tab: its diff opens
    /// (else that web page). Nil leaves the link to its web page. `source`: the chat's pane.
    @MainActor
    static func openFiles(_ url: URL, from source: PaneController, services: AppServices) -> Bool? {
        guard let link = GitHubLink(url), link.files,
              LinkRouter.shared.target(for: url) == .cmuxBrowser, LinkRouter.shared.routing().browserEnabled,
              source.daemon.supports(DaemonCapability.pageTabs.rawValue), case .connected = source.daemon.store.connectionState else { return nil }
        let local = GitHubLocalDiff { [git = services.agentGit.local] in try? await git.read("git.diff", params: $0) }
        PullRequestDiff(local: local, read: { await AgentChatPullRequestReader().diff(url: $0) }).open(link, openDiff: { [weak source, weak services] text in
            guard let source, let services else { return }
            services.viewers.diffPages.open(chatPatch: DiffChatPatch(text: text, folder: "/" + link.reference), in: source, focus: true)
        }, openWeb: { [weak source, weak services] url in
            guard let source, let services else { return }
            _ = services.linkOpener.openWeb(url, from: source, background: false, reusesTab: true)
        })
        return true
    }
}
