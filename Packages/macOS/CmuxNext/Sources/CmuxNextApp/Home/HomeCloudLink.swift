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
    func apply(_ link: Link) async {
        guard link != last else { return }
        if let previous = last, previous.userID != nil, previous.userID != link.userID {
            // The previous account ends before the daemon holds the next
            // one's lease: an op submitted in between is refused here
            // instead of committing under the new account.
            source.configure(commands: previous.endpoint, link: previous.id, identity: nil)
        }
        last = link
        if let endpoint = link.endpoint { await lease.sync(endpoint) }
        let identity = link.userID.map { CloudIdentity(stackUserID: $0, displayName: link.displayName, localID: localID) }
        source.configure(commands: link.endpoint, link: link.id, identity: identity)
    }

    /// The daemon asked for a lease (`cloud-session-needed`).
    func sessionNeeded(reason: String) {
        guard let endpoint = last?.endpoint else { return }
        lease.renew(endpoint, reason: reason) { [source] in source.leaseRenewed() }
    }

    /// Waits for the lease work started so far (tests).
    func settle() async {
        await lease.settle()
    }
}
