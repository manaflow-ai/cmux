import CmuxNextBrowser
import CmuxNextDaemonService
import CmuxNextRemoteLocalhostService
import Foundation

extension PaneController: ChatMachineSignInHost {
    func signInDaemon(for chat: String) -> DaemonService? {
        services.locateTab(chat, onMachine: daemon.machineID).flatMap { try? services.machines.agentDaemon(forTab: $0.0) }
    }

    func signInLifetime(for chat: String) -> @MainActor () -> Bool {
        { [weak services] in services?.locateTab(chat) != nil }
    }

    func signInProfile() -> (wire: String?, engine: BrowserProfileID) {
        let tabs = services.cache.browserTabs
        if tabs.isIncognitoPane(pane) { return (nil, services.windows.incognitoProfile()) }
        let wire = tabs.resolveProfile(pane, nil)
        return (wire, services.browserProfiles.book.engineProfile(for: wire))
    }

    func placeSignInTab(_ make: @escaping @MainActor (_ adopt: @MainActor (any BrowserTab, String?) -> Bool) -> Bool) -> Bool {
        services.linkOpener.open(from: self, kind: .browser) { target, placed in
            make { page, profile in
                target.newBrowserTab(engine: BrowserEngineTag.cef.rawValue, adopting: page, background: placed != nil,
                                     profile: profile, placementOwner: placed != nil, then: placed)
            }
        }
    }

    func openSignInPage(_ url: URL, adopting page: any BrowserTab, profile: String?,
                        prepare: @escaping @MainActor () -> Bool) -> (@MainActor () -> Void)? {
        services.linkOpener.openSignInPage(url, from: self, adopting: page, profile: profile, prepare: prepare)
    }
}
