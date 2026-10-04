import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// The daemon side of the cloud: its proxy commands and its session lease.
typealias HomeCloudEndpoint = CloudConversationCommands & CloudLeaseSessions

/// Follows the local daemon's connection and the signed-in account
/// (home-cloud-proxy.md section 2): each change re-leases the token and
/// reconfigures the cloud source.
final class HomeCloudLink {
    /// The daemon connection with the cloud transport and the account it serves.
    nonisolated struct Link: Equatable, Sendable {
        var endpoint: (any HomeCloudEndpoint)?
        /// The connection the endpoint talks over.
        var id: ObjectIdentifier?
        var userID: String?
        var displayName: String

        static func == (lhs: Link, rhs: Link) -> Bool {
            lhs.id == rhs.id && lhs.userID == rhs.userID && lhs.displayName == rhs.displayName
        }
    }

    private let lease: HomeCloudLease
    private let source: CloudHomeSource
    private let localID: ParticipantID
    private var last: Link?

    init(lease: HomeCloudLease, source: CloudHomeSource, localID: ParticipantID) {
        self.lease = lease
        self.source = source
        self.localID = localID
    }

    /// One observed link. Returns once the source is configured for it.
    ///
    /// The source acts as an account only once the daemon holds that
    /// account's lease: a lease that failed (no token, or a token for
    /// another account because the user switched meanwhile) leaves the
    /// daemon without one and the source holding the account unleased. It
    /// sends no op then and shows nothing that a read did not return for
    /// it; the daemon's next `cloud-session-needed` leases it again.
    func apply(_ link: Link) async {
        guard link != last else { return }
        if let previous = last, previous.userID != nil, previous.userID != link.userID {
            // The previous account ends before the daemon holds the next
            // one's lease: an op submitted in between is refused here
            // instead of committing under the new account.
            source.configure(commands: previous.endpoint, link: previous.id, identity: nil)
        }
        last = link
        guard let endpoint = link.endpoint else {
            // No transport, so no lease and nothing goes out: offline.
            source.configure(commands: nil, link: nil, identity: identity(link.userID, link), leased: false)
            return
        }
        switch await lease.sync(endpoint, expectedUserID: link.userID) {
        case .leased(let subject):
            source.configure(commands: endpoint, link: link.id, identity: identity(subject, link), leased: true)
        case .signedOut:
            source.configure(commands: endpoint, link: link.id, identity: nil)
        case .failed:
            source.configure(commands: endpoint, link: link.id, identity: identity(link.userID, link), leased: false)
        }
    }

    /// The daemon asked for a lease (`cloud-session-needed`): it is for the
    /// account the source acts as when the lease work runs, and only a
    /// lease for that account counts as renewed.
    func sessionNeeded(reason: String) {
        guard let endpoint = last?.endpoint else { return }
        lease.renew(endpoint, reason: reason, expectedUserID: { [source] in source.accountID }) { [source] subject in
            source.leaseRenewed(subject: subject)
        }
    }

    private func identity(_ userID: String?, _ link: Link) -> CloudIdentity? {
        userID.map { CloudIdentity(stackUserID: $0, displayName: link.displayName, localID: localID) }
    }

    /// Waits for the lease work started so far (tests).
    func settle() async {
        await lease.settle()
    }
}
