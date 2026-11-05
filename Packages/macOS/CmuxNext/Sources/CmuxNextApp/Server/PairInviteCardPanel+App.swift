import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemonService
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
            service: .cloud(
                team: { try await pairing.workerTeam()?.id },
                call: { try CloudPairingSource.okValue(try await pairing.call($0, $1)) },
                texts: .init(
                    failed: { RefusalStrings.format("refusal.server.inviteFailed", "Could not make a pairing code: %@", $0) },
                    unreachable: RefusalStrings.text("refusal.server.pairUnreachable", "Could not reach cmux. Check the connection and try again."),
                    notMade: RefusalStrings.text("refusal.server.inviteNotMade", "cmux could not make a pairing code. Try again.")),
                apiBaseURL: feed.apiBaseURL),
            approver: approver,
            // A single-use code: marked concealed and transient (nspasteboard.org) so clipboard managers do not keep it.
            copy: { SystemPasswordPasteboard().write($0, markers: [ConcealedPasteboard.concealedType, ConcealedPasteboard.transientType]) })
        let card = PairInviteCardPanel(model: model)
        let person = PersonInputCheck(sources: services.personInput.sources)
        card.isPersonEvent = { person.isPerson($0) }
        return card
    }
}

