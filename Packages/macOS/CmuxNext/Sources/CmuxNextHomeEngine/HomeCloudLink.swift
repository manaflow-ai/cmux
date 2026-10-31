public import CmuxHomeCore
public import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// The daemon side of the cloud: its proxy commands and its session lease.
public typealias HomeCloudEndpoint = CloudConversationCommands & CloudLeaseSessions

/// Follows the local daemon's connection and the signed-in account
/// (home-cloud-proxy.md section 2): each change re-leases the token and
/// reconfigures the cloud source.
public final class HomeCloudLink {
    /// The daemon connection with the cloud transport and the account it serves.
    public nonisolated struct Link: Equatable, Sendable {
        var endpoint: (any HomeCloudEndpoint)?
        /// The connection the endpoint talks over.
        var id: ObjectIdentifier?
        var userID: String?
        var displayName: String
        /// The chat server (`home.server`): the build's cmux Cloud with the
        /// Stack account (`userID`), or a self-hosted server over Tailscale,
        /// which names the person itself.
        var server: HomeCloudServer

        public init(endpoint: (any HomeCloudEndpoint)? = nil, id: ObjectIdentifier? = nil, userID: String? = nil, displayName: String,
                    server: HomeCloudServer = .hosted) {
            self.endpoint = endpoint
            self.id = id
            self.userID = userID
            self.displayName = displayName
            self.server = server
        }

        public static func == (lhs: Link, rhs: Link) -> Bool {
            lhs.id == rhs.id && lhs.userID == rhs.userID && lhs.displayName == rhs.displayName && lhs.server == rhs.server
        }
    }

    private let lease: HomeCloudLease
    private let source: CloudHomeSource
    private let localID: ParticipantID
    /// The Stack project the account signs in to (the Worker's user ids derive from it).
    private let stackProjectID: String?
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
    /// Runs while forced renewals wait; one asked for meanwhile goes when it
    /// ends. Its first `firstRetry` always runs: a proof only shortens the
    /// rest, so a lease one socket proves while another is refused under
    /// it cannot make forced renewals go back to back.
    private let cooldown: DemandTimer
    /// The cooldown is in its first `firstRetry`.
    private var cooldownInFloor = false
    /// A proof came during that first part: the cooldown ends with it.
    private var provenInFloor = false
    /// The reason of a forced renewal asked for while `cooldown` runs.
    private var pendingForced: String?
    /// The hops and timer deadlines in flight, for tests to wait on.
    let probe = HomeCloudLinkProbe()

    /// `clock` runs the retry backoff; tests pass a manual clock.
    public init(lease: HomeCloudLease, source: CloudHomeSource, localID: ParticipantID, stackProjectID: String? = nil,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.lease = lease
        self.source = source
        self.localID = localID
        self.stackProjectID = stackProjectID
        retry = DemandTimer(owner: "App.homeCloud.leaseRetry", clock: clock)
        cooldown = DemandTimer(owner: "App.homeCloud.renewCooldown", clock: clock)
        source.onLeaseMissing { [weak self, probe] in
            probe.hopStarted()
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in
                self?.leaseMissing()
                probe.hopEnded()
            }
        }
        source.onLeaseProven { [weak self, probe] in
            probe.hopStarted()
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in
                self?.leaseProven()
                probe.hopEnded()
            }
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
    ///
    /// A self-hosted server (`link.server`) needs no Stack account: the
    /// daemon leases it without a token and the server names the person, so
    /// a Stack sign-in or sign-out changes nothing there. Another server is
    /// another account: the previous one ends first.
    public func apply(_ link: Link) async {
        guard link != last else { return }
        if let previous = last, previous.id == link.id, previous.server == link.server,
           previous.userID == link.userID || link.server != .hosted {
            last = link
            if link.server == .hosted, let identity = identity(link.userID, link) { source.rename(identity) }
            return
        }
        if let previous = last, previous.server != link.server || (previous.userID != nil && previous.userID != link.userID) {
            // The previous account ends before the daemon holds the next
            // one's lease: an op submitted in between is refused here
            // instead of committing under the new account.
            source.configure(commands: previous.endpoint, link: previous.id, identity: nil)
        }
        last = link
        retry.cancel()
        retryDelay = Self.firstRetry
        cooldown.cancel()
        cooldownInFloor = false
        provenInFloor = false
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
        probe.setLeasing(leasing)
        let outcome = await lease.sync(endpoint, expectedUserID: link.userID, server: link.server)
        leasing -= 1
        switch outcome {
        case .leased(let subject, let expiresAt):
            leasedExpiry = expiresAt
            source.configure(commands: endpoint, link: link.id, identity: identity(subject, link), leased: true)
        case .selfHosted(let info):
            source.configure(commands: endpoint, link: link.id, identity: selfHostedIdentity(info), leased: true)
        case .signedOut:
            source.configure(commands: endpoint, link: link.id, identity: nil)
        case .failed, .superseded:
            // A self-hosted server that did not answer names nobody yet: the retry asks it again.
            let pending = link.server == .hosted ? identity(link.userID, link) : nil
            source.configure(commands: endpoint, link: link.id, identity: pending, leased: false)
        }
        settled(outcome, reason: "missing")
        // Published after the follow-up work above, so a test that waits
        // for idle never sees the gap between two lease steps.
        probe.setLeasing(leasing)
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
    public func sessionNeeded(reason: String, expiresAt: UInt64? = nil) {
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
    /// takes its token, so the forced wait starts over. The cooldown ends
    /// (at the end of its first `firstRetry` when it is still in it) and a
    /// renewal that waited for it goes then.
    private func leaseProven() {
        forcedWait = .zero
        if cooldownInFloor {
            provenInFloor = true
            return
        }
        cooldown.cancel()
        sendPendingForced()
    }

    /// The forced renewal that waited for the cooldown, once no cooldown
    /// runs and no lease work is in flight; otherwise it stays for later.
    private func sendPendingForced() {
        guard let reason = pendingForced, leasing == 0, !cooldown.isScheduled else { return }
        pendingForced = nil
        renew(reason: reason)
    }

    /// `missing` takes the current token; the others refresh it.
    private static func isForced(_ reason: String) -> Bool { reason != "missing" }

    /// `answering`: the expiry the daemon's request named; once a new lease
    /// holds, a late request naming it needs nothing more.
    private func renew(reason: String, answering expiry: UInt64? = nil) {
        guard let current = last, let endpoint = current.endpoint else { return }
        leasing += 1
        probe.setLeasing(leasing)
        lease.renew(endpoint, reason: reason, server: current.server,
                    expectedUserID: { [source] in source.accountID }) { [weak self, source] outcome in
            if case .leased(let subject, let expiresAt) = outcome {
                if let expiry, expiry != expiresAt { self?.answered(expiry) }
                self?.leasedExpiry = expiresAt
                source.leaseRenewed(subject: subject)
            }
            // The server named the person again (the first time, after a failed lease): the
            // source acts as them on the link it was asked for, unless a newer link replaced it.
            if case .selfHosted(let info) = outcome, let self, last?.id == current.id, last?.server == current.server {
                source.configure(commands: endpoint, link: current.id, identity: selfHostedIdentity(info), leased: true)
            }
            guard let self else { return }
            leasing -= 1
            if case .leased = outcome, Self.isForced(reason) { startCooldown() }
            settled(outcome, reason: reason)
            sendPendingForced()
            probe.setLeasing(leasing)
        }
    }

    /// A forced renewal succeeded: the next one waits, twice as long as the
    /// last wait, unless a reply or a live socket proves this lease first.
    private func startCooldown() {
        forcedWait = forcedWait == .zero ? Self.firstRetry : min(forcedWait * 2, Self.maxRetry)
        let rest = forcedWait - Self.firstRetry
        cooldownInFloor = true
        provenInFloor = false
        cooldown.schedule(after: Self.firstRetry) { @MainActor [weak self, probe] in
            self?.cooldownFloorPassed(rest: rest)
            probe.fired()
        }
    }

    /// The cooldown's first `firstRetry` passed: it ends now when a proof
    /// came meanwhile or nothing of it is left, else it runs the rest.
    private func cooldownFloorPassed(rest: Duration) {
        cooldownInFloor = false
        guard !provenInFloor, rest > .zero else {
            provenInFloor = false
            // Lease work running now keeps it; it goes when that work ends.
            sendPendingForced()
            return
        }
        cooldown.schedule(after: rest) { @MainActor [weak self, probe] in
            self?.sendPendingForced()
            probe.fired()
        }
    }

    /// A lease that holds ends the backoff; a failed one is tried again
    /// after it. No account (signed out) or newer work needs no retry.
    private func settled(_ outcome: HomeCloudLease.Outcome, reason: String) {
        switch outcome {
        case .leased, .selfHosted:
            retry.cancel()
            retryDelay = Self.firstRetry
        case .failed:
            guard !retry.isScheduled else { return }
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maxRetry)
            retry.schedule(after: delay) { @MainActor [weak self, probe] in
                defer { probe.fired() }
                guard let self, leasing == 0 else { return }
                renew(reason: reason)
            }
        case .signedOut, .superseded:
            break
        }
    }

    /// The person a self-hosted server named: its user id is both the
    /// account and the participant (no Stack project derives it).
    private func selfHostedIdentity(_ info: CloudSelfHostInfo) -> CloudIdentity {
        let name = info.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? info.login
        return CloudIdentity(stackUserID: info.userID, displayName: name, localID: localID)
    }

    private func identity(_ userID: String?, _ link: Link) -> CloudIdentity? {
        userID.map { CloudIdentity(stackUserID: $0, displayName: link.displayName, localID: localID, stackProjectID: stackProjectID) }
    }

    #if DEBUG
    /// Waits until the hops started so far ran and the lease work they and
    /// earlier calls started ended, with what that work started in turn
    /// (tests): one wait on the probe's idle signal. A timer deadline that
    /// passed is not covered: wait for it with `timersFired(atLeast:)`.
    func settle() async {
        await probe.wait { $0.isIdle }
    }

    /// Waits until the link handled `count` timer deadlines in all (tests).
    func timersFired(atLeast count: Int) async {
        await probe.wait { $0.fires >= count }
    }
    #endif
}
