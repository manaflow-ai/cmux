import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextServer
import Foundation

extension PairInviteCardPanel {
    /// The App's Pair Another Machine card: the invite minted and watched as the signed-in user, its
    /// arrived machine previewed and approved by Add Server's own cloud source (with no local server
    /// status behind it: the card reads none), and Confirm answering only the person's own click.
    @MainActor
    static func app(services: AppServices) -> PairInviteCardPanel {
        let feed = services.feed
        let call: CloudPairingSource.Call = { [weak feed] path, body in
            guard let feed else { throw FeedServiceError.signedOut }
            return try await feed.call(path, body)
        }
        let pairing = CloudPairingSource(
            inner: NoLocalServerSource(), call: call,
            account: { [weak auth = services.cloud.auth] in
                guard let auth, auth.isSignedIn else { return nil }
                return auth.user?.displayName ?? auth.user?.primaryEmail ?? ""
            },
            chiefPlaced: { [weak services] in services?.home.refreshChiefTab() })
        let approver = ServerModel(source: pairing)
        approver.start()
        let model = PairInviteModel(
            service: .app(pairing: pairing, call: call, apiBaseURL: feed.apiBaseURL), approver: approver,
            // A single-use code: marked concealed and transient (nspasteboard.org) so clipboard managers do not keep it.
            copy: { SystemPasswordPasteboard().write($0, markers: [ConcealedPasteboard.concealedType, ConcealedPasteboard.transientType]) })
        let card = PairInviteCardPanel(model: model)
        let person = PersonInputCheck(sources: services.personInput.sources)
        card.isPersonEvent = { person.isPerson($0) }
        return card
    }
}

/// The invite card's approver needs no local server status: preview and approve go to the cloud
/// (``CloudPairingSource``), so its inner source answers nothing.
@MainActor
private final class NoLocalServerSource: ServerSource {
    func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {}
    func send(_ intent: ServerIntent) {}
    func stop() {}
}
