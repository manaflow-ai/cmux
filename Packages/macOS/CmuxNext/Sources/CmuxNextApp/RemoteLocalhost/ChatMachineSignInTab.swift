import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemonService
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
              let daemon = try? services.machines.agentDaemon(forTab: tab) else { return nil }
        guard let port = AgentPaneSignInPage.callbackPort(url), isAvailable(on: daemon, services: services) else { return nil }
        return { [weak pane] in
            guard pane != nil else { return false }
            // task-owner: one page made and one tab asked for; ends once the tab is asked for.
            Task { @MainActor [weak pane] in
                guard let pane else { return }
                _ = await open(url, daemon: daemon, from: pane, callbackPort: port, owner: chatOwner(key), checking: { [weak services] in
                    services?.locateTab(key) != nil
                })
            }
            return true
        }
    }

    private static func isAvailable(on daemon: DaemonService, services: AppServices) -> Bool {
        guard case .machine = services.remoteLocalhost.route(daemon: daemon, workspace: nil, engine: .cef) else { return false }
        return services.cache.browserTabs.cefUnavailable() == nil
    }

    /// Opens the approval page using the chat machine's existing browser placement and callback route.
    static func open(_ url: URL, daemon: DaemonService, from source: PaneController,
                     callbackPort: UInt16, owner: String, checking current: @escaping @MainActor () -> Bool,
                     onOpened: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil) async -> Bool {
        let services = source.services
        guard current(), isAvailable(on: daemon, services: services) else { return false }
        // An adopted tab stays in the profile it was created in.
        let browserTabs = services.cache.browserTabs
        let incognito = browserTabs.isIncognitoPane(source.pane)
        let wire = incognito ? nil : browserTabs.resolveProfile(source.pane, nil)
        let profile = incognito ? services.windows.incognitoProfile() : services.browserProfiles.book.engineProfile(for: wire)
        let configuration = BrowserTabConfiguration(profile: profile, initialURL: url, navigationGuard: .noLoopback)
        guard let page = try? await services.cache.makeCEFTab(configuration) else { return false }
        guard !Task.isCancelled, current() else { page.close(); return false }
        let prepare: @MainActor () -> Bool = { [weak services, weak page] in
            guard let services, let page, current() else { return false }
            services.remoteLocalhost.expectCallbackPage(page, machine: daemon.machineID, port: callbackPort, owner: owner,
                                                        current: current, closePending: { [weak services, weak page] in
                guard let page else { return }
                services?.cache.pageRequests.browserTab(page, didRequest: .close)
                page.close()
            })
            return true
        }
        guard let onOpened else {
            return services.linkOpener.open(from: source, kind: .browser) { target, placed in
                guard prepare() else { page.close(); return false }
                let made = target.newBrowserTab(url: nil, engine: BrowserEngineTag.cef.rawValue, adopting: page,
                                                background: placed != nil, profile: wire, placementOwner: placed != nil, then: placed)
                if !made { page.close() }
                return made
            }
        }
        guard let back = services.linkOpener.openSignInPage(url, from: source, adopting: page, profile: wire, prepare: prepare)
        else { page.close(); return false }
        onOpened { [weak services] in
            back()
            if let services { closeApproval(owner: owner, services: services) }
        }
        return true
    }

    static func chatOwner(_ key: String) -> String { "chat:" + key }

    static func closeApproval(owner: String, services: AppServices) {
        for key in services.remoteLocalhost.endSignInApproval(owner: owner) {
            services.cache.pageRequests.closeTab(key)
        }
    }
}
