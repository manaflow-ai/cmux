import CmuxNextBrowser
import CmuxNextRemoteLocalhostService
import Foundation

/// Claude's automatic sign-in page for a Cloud chat (AgentPaneSignInPage.swift; Leo 2026-11-02:
/// "one click plus the provider's approve page, with nothing else"): a Chromium tab beside the
/// chat, in the person's own browser store, so their claude.com sign-in is used, whose localhost is
/// the chat's machine. The approve redirects to `http://localhost:<port>/callback`, Claude's own
/// listener on that machine; remote localhost (`loopback-forward-v1`) re-makes the page in that
/// machine's derived store and carries the bytes. cmux never reads or keeps the code or the token.
///
/// The page is made here, in the profile's store with a `.noLoopback` guard, and adopted by a new
/// tab, which takes the chat's machine for its loopback pages (``RemoteLocalhostService/expectPage(_:machine:)``),
/// whichever tree holds it. An adopted page is never a machine-run browser of a remote workspace.
@MainActor
enum ChatMachineSignInTab {
    /// The open of `url` for agent tab `key`'s chat from `pane`; nil, with nothing spent, when no
    /// such tab can be made: the chat is not on another machine, that machine has no remote
    /// localhost (an older cmux-tui, the setting off), or Chromium is not available. The card then
    /// opens the page that gives a code to paste.
    static func opener(for url: URL, agentTab key: String, from pane: PaneController) -> (@MainActor () -> Bool)? {
        let services = pane.services
        guard let (tab, _) = services.locateTab(key, onMachine: pane.daemon.machineID),
              let daemon = try? services.machines.agentDaemon(forTab: tab),
              case .machine = services.remoteLocalhost.route(daemon: daemon, workspace: nil, engine: .cef),
              services.cache.browserTabs.cefUnavailable() == nil else { return nil }
        let machine = daemon.machineID
        return { [weak pane] in
            guard pane != nil else { return false }
            // task-owner: one page made and one tab asked for; ends once the tab is asked for.
            Task { @MainActor [weak pane] in
                guard let source = pane else { return }
                // The page is made in the store the new tab gets: the profile a new browser tab
                // in this workspace takes (its own, the room's or `default`), or the incognito one
                // in an incognito window. The tab is asked for with that same profile, so the
                // adopted page never crosses profiles.
                let browserTabs = services.cache.browserTabs
                let incognito = browserTabs.isIncognitoPane(source.pane)
                let wire = incognito ? nil : browserTabs.resolveProfile(source.pane, nil)
                let profile = incognito ? services.windows.incognitoProfile() : services.browserProfiles.book.engineProfile(for: wire)
                let configuration = BrowserTabConfiguration(profile: profile, initialURL: url, navigationGuard: .noLoopback)
                guard let page = try? await services.cache.makeCEFTab(configuration) else { return }
                guard let pane else { return page.close() }
                services.remoteLocalhost.expectPage(page, machine: machine)
                services.linkOpener.open(from: pane, kind: .browser) { target, placed in
                    target.newBrowserTab(url: nil, engine: BrowserEngineTag.cef.rawValue, adopting: page,
                                         background: placed != nil, profile: wire, placementOwner: placed != nil, then: placed)
                }
            }
            return true
        }
    }
}
