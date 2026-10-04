import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
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
    /// Lease work started and not finished. A missing lease asks for a new
    /// one only while none is in flight: that one's outcome answers it.
    private var leasing = 0
    /// The first wait before a failed lease is tried again; each failure
    /// doubles it up to `maxRetry`, and a lease that holds resets it.
    static let firstRetry: Duration = .seconds(1)
    static let maxRetry: Duration = .seconds(60)
    private var retryDelay = HomeCloudLink.firstRetry
    /// The pending retry; cancelled by a new link, a lease that holds, or
    /// this link ending.
    private let retry: DemandTimer

    /// `clock` runs the retry backoff; tests pass a manual clock.
    init(lease: HomeCloudLease, source: CloudHomeSource, localID: ParticipantID, clock: any Clock<Duration> = ContinuousClock()) {
        self.lease = lease
        self.source = source
        self.localID = localID
        retry = DemandTimer(owner: "App.homeCloud.leaseRetry", clock: clock)
        source.onLeaseMissing { [weak self] in
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in self?.leaseMissing() }
        }
    }

    /// One observed link. Returns once the source is configured for it.
    ///
    /// The source acts as an account only once the daemon holds that
    /// account's lease: a lease that failed (no token, or a token for
    /// another account because the user switched meanwhile) leaves the
    /// daemon without one and the source holding the account unleased. It
    /// sends no op and makes no read then. The daemon asks again only when a
    /// command reaches it, and none does, so the source asks instead: an op
    /// or read it refused for the missing lease leases again
    /// (`leaseMissing`), and a failed lease is tried again after a backoff
    /// until it holds or the link changes. A new display name alone is the
    /// same account on the same connection and keeps the lease.
    func apply(_ link: Link) async {
        guard link != last else { return }
        if let previous = last, previous.id == link.id, previous.userID == link.userID {
            last = link
            if let identity = identity(link.userID, link) { source.rename(identity) }
            return
        }
        if let previous = last, previous.userID != nil, previous.userID != link.userID {
            // The previous account ends before the daemon holds the next
            // one's lease: an op submitted in between is refused here
            // instead of committing under the new account.
            source.configure(commands: previous.endpoint, link: previous.id, identity: nil)
        }
        last = link
        retry.cancel()
        retryDelay = Self.firstRetry
        guard let endpoint = link.endpoint else {
            // No transport, so no lease and nothing goes out: offline.
            source.configure(commands: nil, link: nil, identity: identity(link.userID, link), leased: false)
            return
        }
        leasing += 1
        let outcome = await lease.sync(endpoint, expectedUserID: link.userID)
        leasing -= 1
        switch outcome {
        case .leased(let subject):
            source.configure(commands: endpoint, link: link.id, identity: identity(subject, link), leased: true)
        case .signedOut:
            source.configure(commands: endpoint, link: link.id, identity: nil)
        case .failed, .superseded:
            source.configure(commands: endpoint, link: link.id, identity: identity(link.userID, link), leased: false)
        }
        settled(outcome, reason: "missing")
    }

    /// The daemon asked for a lease (`cloud-session-needed`): it is for the
    /// account the source acts as when the lease work runs, and only a
    /// lease for that account counts as renewed.
    func sessionNeeded(reason: String) {
        renew(reason: reason)
    }

    /// The source refused an op or a read because the daemon holds no lease
    /// for its account.
    private func leaseMissing() {
        guard leasing == 0 else { return }
        retry.cancel()
        renew(reason: "missing")
    }

    private func renew(reason: String) {
        guard let endpoint = last?.endpoint else { return }
        leasing += 1
        lease.renew(endpoint, reason: reason, expectedUserID: { [source] in source.accountID }) { [weak self, source] outcome in
            if case .leased(let subject) = outcome { source.leaseRenewed(subject: subject) }
            guard let self else { return }
            leasing -= 1
            settled(outcome, reason: reason)
        }
    }

    /// A lease that holds ends the backoff; a failed one is tried again
    /// after it. No account (signed out) or newer work needs no retry.
    private func settled(_ outcome: HomeCloudLease.Outcome, reason: String) {
        switch outcome {
        case .leased:
            retry.cancel()
            retryDelay = Self.firstRetry
        case .failed:
            guard !retry.isScheduled else { return }
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maxRetry)
            retry.schedule(after: delay) { @MainActor [weak self] in
                guard let self, leasing == 0 else { return }
                renew(reason: reason)
            }
        case .signedOut, .superseded:
            break
        }
    }

    private func identity(_ userID: String?, _ link: Link) -> CloudIdentity? {
        userID.map { CloudIdentity(stackUserID: $0, displayName: link.displayName, localID: localID) }
    }

    #if DEBUG
    /// Waits for the lease work started so far (tests).
    func settle() async {
        await lease.settle()
    }
    #endif
}
