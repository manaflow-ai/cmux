import AppKit
import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages

extension InternalPageID {
    static let homeChannels = InternalPageID(rawValue: "home-channels")
}

extension PageDescriptor {
    /// The channels Home (webviews/src/pages/home-channels): a React Home over the same Home owners
    /// the native Home reads. `cmux.home.` is granted to this first-party page only (an app page
    /// cannot claim a `cmux.` namespace, and no other descriptor lists it). Sends and reactions
    /// count only on the person's own gesture, so page script cannot post as the user on its own.
    static let homeChannels = PageDescriptor(
        id: "cmux.home-channels", resource: "home-channels", namespaces: ["cmux.home."])
}

extension PageFactory {
    /// The React channels Home when Debug Settings `home.surface` is `web`, else nil (the native
    /// Home). The tunable goes when one Home becomes the only one.
    func homeChannelsWebPage() -> PageWebView? {
        guard PageTunables.home.value == .web else { return nil }
        let home = services.home
        let provider = HomeChannelsPageProvider(source: home.homeRouter, me: ParticipantID(ConversationParticipant.localUserID))
        let routes = [PageRoute(prefix: "cmux.home.", provider: provider)]
        guard let page = PageWebView(descriptor: .homeChannels, routes: routes, surface: .home) else { return nil }
        home.homeDidOpen()
        return page
    }
}
