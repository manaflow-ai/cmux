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
    /// doubles it up to `maxRetry`, and a lease that holds resets it. The
    /// same steps space forced renewals (`forcedWait`).
    static let firstRetry: Duration = .seconds(1)
    static let maxRetry: Duration = .seconds(60)
    private var retryDelay = HomeCloudLink.firstRetry
    /// The pending retry; cancelled by a new link, a lease that holds, or
    /// this link ending.
    private let retry: DemandTimer
    /// The expiry of the lease this link set last.
    private var leasedExpiry: UInt64? {
        didSet {
            guard let oldValue, oldValue != leasedExpiry else { return }
            answered(oldValue)
        }
    }
    /// Expiries a lease this link set replaced: its own earlier leases, and
    /// the leases a renewal answered (one another local client set
    /// included). A daemon request that names one of them is already
    /// answered. Any other expiry (a lease another trusted local client set
    /// and nothing replaced yet) is renewed. The newest few are kept.
    private var replacedExpiries: [UInt64] = []
    static let replacedExpiryLimit = 8
    /// How long a forced renewal waits after a forced renewal that
    /// succeeded. Zero until one succeeds; each doubles it up to
    /// `maxRetry`, and only a reply or a live socket on a lease (not the
    /// lease itself) resets it, so a Worker that refuses every new token
    /// cannot make renewals and resends loop.
    private var forcedWait: Duration = .zero
    /// Runs while forced renewals wait; one asked for meanwhile goes when it ends.
    private let cooldown: DemandTimer
    /// The reason of a forced renewal asked for while `cooldown` runs.
    private var pendingForced: String?

    /// `clock` runs the retry backoff; tests pass a manual clock.
    init(lease: HomeCloudLease, source: CloudHomeSource, localID: ParticipantID, clock: any Clock<Duration> = ContinuousClock()) {
        self.lease = lease
        self.source = source
        self.localID = localID
        retry = DemandTimer(owner: "App.homeCloud.leaseRetry", clock: clock)
        cooldown = DemandTimer(owner: "App.homeCloud.renewCooldown", clock: clock)
        source.onLeaseMissing { [weak self] in
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in self?.leaseMissing() }
        }
        source.onLeaseProven { [weak self] in
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in self?.leaseProven() }
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
        cooldown.cancel()
        pendingForced = nil
        forcedWait = .zero
        leasedExpiry = nil
        replacedExpiries = []
        guard let endpoint = link.endpoint else {
            // No transport, so no lease and nothing goes out: offline.
            source.configure(commands: nil, link: nil, identity: identity(link.userID, link), leased: false)
            return
        }
        leasing += 1
        let outcome = await lease.sync(endpoint, expectedUserID: link.userID)
        leasing -= 1
        switch outcome {
        case .leased(let subject, let expiresAt):
            leasedExpiry = expiresAt
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
    ///
    /// Every upstream socket refused with one token asks (the inbox and up
    /// to 64 conversations), so one renewal answers them all: a request
    /// that names a lease this link already replaced (`expiresAt`), or that
    /// arrives while lease work is queued or running, needs nothing more. A
    /// forced renewal asked for soon after one succeeded waits
    /// (`forcedWait`).
    func sessionNeeded(reason: String, expiresAt: UInt64? = nil) {
        if let expiresAt, replacedExpiries.contains(expiresAt) { return }
        guard leasing == 0 else { return }
        if Self.isForced(reason), cooldown.isScheduled {
            pendingForced = reason
            return
        }
        renew(reason: reason, answering: expiresAt)
    }

    private func answered(_ expiry: UInt64) {
        replacedExpiries.removeAll { $0 == expiry }
        replacedExpiries.append(expiry)
        if replacedExpiries.count > Self.replacedExpiryLimit { replacedExpiries.removeFirst() }
    }

    /// The source refused an op or a read because the daemon holds no lease
    /// for its account.
    private func leaseMissing() {
        guard leasing == 0 else { return }
        retry.cancel()
        renew(reason: "missing")
    }

    /// A reply or a live socket came through the current lease: the Worker
    /// takes its token, so a later forced renewal need not wait.
    private func leaseProven() {
        forcedWait = .zero
    }

    /// `missing` takes the current token; the others refresh it.
    private static func isForced(_ reason: String) -> Bool { reason != "missing" }

    /// `answering`: the expiry the daemon's request named; once a new lease
    /// holds, a late request naming it needs nothing more.
    private func renew(reason: String, answering expiry: UInt64? = nil) {
        guard let endpoint = last?.endpoint else { return }
        leasing += 1
        lease.renew(endpoint, reason: reason, expectedUserID: { [source] in source.accountID }) { [weak self, source] outcome in
            if case .leased(let subject, let expiresAt) = outcome {
                if let expiry, expiry != expiresAt { self?.answered(expiry) }
                self?.leasedExpiry = expiresAt
                source.leaseRenewed(subject: subject)
            }
            guard let self else { return }
            leasing -= 1
            if case .leased = outcome, Self.isForced(reason) { startCooldown() }
            settled(outcome, reason: reason)
        }
    }

    /// A forced renewal succeeded: the next one waits, twice as long as the
    /// last wait, unless a reply or a live socket proves this lease first.
    private func startCooldown() {
        forcedWait = forcedWait == .zero ? Self.firstRetry : min(forcedWait * 2, Self.maxRetry)
        cooldown.schedule(after: forcedWait) { @MainActor [weak self] in
            guard let self, let reason = pendingForced else { return }
            pendingForced = nil
            guard leasing == 0 else { return }
            renew(reason: reason)
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
