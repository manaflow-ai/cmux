import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHome
import MessagesLabHome

/// What a Chief card's buttons do on this Mac (cmux issue 25830, `card` parts):
/// - Open browser (`browser:right`): the browser tab in the column right of the Home chat is
///   selected, the one the Chief drives with `cmux browser right` (its own agent-profile tab first,
///   else the tab the column shows, else its last browser tab). Only the Home workspace shows; no
///   other workspace is activated. With no browser there, the card's page opens beside Home.
/// - Open desktop (`machine:<id>`): the Cloud machine's Open Desktop action (`cloud open-desktop`).
/// - Add (a sign-in card): the sheet's sign-in goes into the Chief Secure Store (`ChiefSecureStore`,
///   the login keychain), off the main thread; the shown cards then say Added.
@MainActor
enum HomeChiefCardActions {
    /// Wires `transcript`'s card buttons and loads the Secure Store's sites once.
    static func wire(_ transcript: HomeNativeTranscriptView, services: AppServices, openLink: @escaping @MainActor (URL) -> Void) {
        transcript.onChiefCardOpen = { [weak services] target, url in
            guard let services else { return }
            open(target, url: url, services: services, openLink: openLink)
        }
        transcript.enableChiefSignIn { site, username, password in
            await save(site: site, username: username, password: password)
        }
        loadSites()
    }

    static func open(_ target: ChiefCard.Target, url: String?, services: AppServices, openLink: @MainActor (URL) -> Void) {
        switch target {
        case .machine(let id):
            let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: id), origin: .user)
            _ = services.registry.perform("cloudOpenDesktop", invocation: invocation)
        case .browserRight:
            if let tab = browserRightTab(services), services.revealTab(tab, intent: .bringForward) { return }
            if let url, let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? "") { openLink(link) }
        }
    }

    /// The browser tab in the column right of the Home chat, or nil.
    static func browserRightTab(_ services: AppServices) -> String? {
        let store = services.machines.local.store
        guard let home = services.home.homeWorkspace, let chat = HomeDock.pageTab(in: home)?.pane,
              let beside = AgentProcessTerminal.besidePane(of: chat, in: store) else { return nil }
        let browsers = beside.tabs.filter { $0.kind == .browser && $0.page == nil }
        let agent = browsers.last { $0.browserProfileID?.lowercased() == AgentBrowserProfile.id }
        let shown = beside.tabs.enumerated().first { $0.offset == beside.defaultTabIndex }?.element
        let selected = shown.flatMap { tab in browsers.first { $0.id == tab.id } }
        return (agent ?? selected ?? browsers.last)?.id
    }

    /// Saves the sign-in off the main thread; true when it is in the store.
    static func save(site: String, username: String, password: String) async -> Bool {
        let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
            (try? ChiefSecureStore().save(site: site, username: username, password: password)) != nil
        }.value
        if saved, let normalized = ChiefSecureStore.normalized(site) {
            MessagesLabHomeView.chiefSecureStoreSites.insert(normalized)
        }
        return saved
    }

    /// The Secure Store's sites, read once off the main thread (a sign-in card then shows Added).
    static func loadSites() {
        guard !sitesLoaded else { return }
        sitesLoaded = true
        // task-owner: one keychain read; ends when the sites are set
        Task {
            let sites = await Task.detached(priority: .utility) { ChiefSecureStore().sites() }.value
            MessagesLabHomeView.chiefSecureStoreSites.formUnion(sites)
        }
    }

    private static var sitesLoaded = false
}
