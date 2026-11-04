public import AppKit
public import CmuxHomeCore
public import MessagesLabHome

/// What the app gives a Chief card's buttons (cmux issue 25830); `AppServices` conforms with one-line
/// forwards.
public protocol HomeChiefCardHost: AnyObject {
    /// The browser tab in the column right of the Home chat (`HomeDock.chiefBrowserTab`), or nil.
    func chiefCardBrowserTab() -> String?
    /// Selects tab `id` (its window and the Home workspace come forward; no other workspace activates).
    func chiefCardReveal(tab id: String) -> Bool
    /// The Cloud machine's Open Desktop action (`cloud open-desktop`).
    func chiefCardOpenDesktop(machine id: String)
    /// Saves a sign-in in the Chief Secure Store (the login keychain), off the main thread.
    func chiefCardSave(site: String, username: String, password: String) async -> Bool
    /// The Secure Store's sites (no passwords read), off the main thread.
    func chiefCardStoredSites() async -> [String]
}

/// What a Chief card's buttons do on this Mac (cmux issue 25830, `card` parts):
/// - Open browser (`browser:right`): the browser tab right of the Home chat is selected, the one the
///   Chief drives with `cmux browser right`. With no browser there, the card's page opens beside Home.
/// - Open desktop (`machine:<id>`): the Cloud machine's Open Desktop action.
/// - Add (a sign-in card): the sheet's sign-in goes into the Chief Secure Store; the shown cards then
///   say Added.
/// One per app (the Home service holds it): its ``HomeChiefCardState`` is shared by every Home transcript.
public final class HomeChiefCardActions {
    /// The Secure Store's sites every transcript's cards read.
    public let state = HomeChiefCardState()
    /// The keychain was read once (later saves update the state directly).
    private var sitesLoaded = false

    public init() {}

    /// Wires `transcript`'s card buttons and state, and loads the Secure Store's sites once.
    public func wire(_ transcript: HomeNativeTranscriptView, host: any HomeChiefCardHost, openLink: @escaping (URL) -> Void) {
        transcript.chiefCardState = state
        transcript.onChiefCardOpen = { [weak host] target, url in
            guard let host else { return }
            Self.open(target, url: url, host: host, openLink: openLink)
        }
        transcript.enableChiefSignIn { [weak self, weak host] site, username, password in
            guard let self, let host, await host.chiefCardSave(site: site, username: username, password: password) else { return false }
            self.state.addStoredSite(site)
            return true
        }
        loadSites(host)
    }

    static func open(_ target: ChiefCard.Target, url: String?, host: any HomeChiefCardHost, openLink: (URL) -> Void) {
        switch target {
        case .machine(let id):
            host.chiefCardOpenDesktop(machine: id)
        case .browserRight:
            if let tab = host.chiefCardBrowserTab(), host.chiefCardReveal(tab: tab) { return }
            if let url, let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? "") { openLink(link) }
        }
    }

    private func loadSites(_ host: any HomeChiefCardHost) {
        guard !sitesLoaded else { return }
        sitesLoaded = true
        // task-owner: one keychain read; ends when the sites are set
        Task { [state, weak host] in
            guard let sites = await host?.chiefCardStoredSites() else { return }
            state.setStoredSites(state.storedSites.union(sites.map { $0.lowercased() }))
        }
    }
}
