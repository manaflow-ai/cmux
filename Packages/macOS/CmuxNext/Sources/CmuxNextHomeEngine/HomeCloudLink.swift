public import CmuxHomeCore
public import CmuxNextDaemon
import CmuxNextHomeModel
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
    /// The link the rules act on, with its endpoint (the rules see only whether it has one).
    private var last: Link?
    /// The lease state machine's state: the rules are the Rust op `cloud.link_step`
    /// (cmux-home-rules `cloud/link.rs`); this runs the effects each step returns.
    private var state = LinkState()
    /// The pending retry of a failed lease.
    private let retry: DemandTimer
    /// Runs while forced renewals wait (its first second, then the rest).
    private let cooldown: DemandTimer
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
                self?.handle(.init(kind: "leaseMissing"))
                probe.hopEnded()
            }
        }
        source.onLeaseProven { [weak self, probe] in
            probe.hopStarted()
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in
                self?.handle(.init(kind: "leaseProven"))
                probe.hopEnded()
            }
        }
    }

    /// One observed link. Returns once the source is configured for it.
    ///
    /// The source acts as an account only once the daemon holds that
    /// account's lease; a failed lease is tried again after a backoff until
    /// it holds or the link changes. A new display name alone keeps the
    /// lease. A self-hosted server needs no Stack account; another server is
    /// another account, and the previous one ends first.
    public func apply(_ link: Link) async {
        let previous = last
        let effects = step(.init(kind: "apply", link: WireLink(link)))
        if WireLink(link) != previous.map(WireLink.init) { last = link }
        guard let sync = run(effects, links: [previous, link]), let endpoint = link.endpoint else { return }
        let outcome = await lease.sync(endpoint, expectedUserID: sync.expectedUserId, server: link.server)
        run(step(.init(kind: "synced", link: WireLink(link), outcome: WireOutcome(outcome))), links: [link])
        // Published after the follow-up work above, so a test that waits
        // for idle never sees the gap between two lease steps.
        probe.setLeasing(Int(state.leasing))
    }

    /// The daemon asked for a lease (`cloud-session-needed`). A request that
    /// names a lease this link already replaced (`expiresAt`), or that
    /// arrives while lease work runs, needs nothing more; a forced renewal
    /// soon after one succeeded waits for the cooldown.
    public func sessionNeeded(reason: String, expiresAt: UInt64? = nil) {
        handle(.init(kind: "sessionNeeded", reason: reason, expiresAt: expiresAt))
    }

    private func handle(_ event: LinkEvent) {
        run(step(event), links: [])
    }

    /// One `cloud.link_step`: the new state and the effects to run.
    private func step(_ event: LinkEvent) -> [LinkEffect] {
        do {
            let reply: LinkReply = try HomeRules.call("cloud.link_step", LinkRequest(state: state, event: event))
            state = reply.state
            return reply.effects
        } catch {
            assertionFailure("cloud.link_step: \(error)")
            return []
        }
    }

    /// Runs `effects` in order. `links`: the Swift links an effect's link can
    /// name (by the rules' equality), besides `last`. Returns a `sync` effect
    /// for the caller to await.
    @discardableResult
    private func run(_ effects: [LinkEffect], links: [Link?]) -> LinkEffect? {
        func resolve(_ wire: WireLink?) -> Link? {
            guard let wire else { return nil }
            return (links + [last]).lazy.compactMap { $0 }.first { WireLink($0) == wire }
        }
        var sync: LinkEffect?
        for effect in effects {
            switch effect.kind {
            case "rename":
                if let identity = effect.identity { source.rename(cloudIdentity(identity)) }
            case "configure":
                let link = resolve(effect.link)
                source.configure(commands: effect.commands == "endpoint" ? link?.endpoint : nil, link: link?.id,
                                 identity: effect.identity.map(cloudIdentity), leased: effect.leased ?? true)
            case "sync":
                probe.setLeasing(Int(state.leasing))
                sync = effect
            case "renew":
                if let link = resolve(effect.link) { renew(effect, on: link) }
            case "leaseRenewed":
                if let subject = effect.subject { source.leaseRenewed(subject: subject) }
            case "scheduleRetry":
                retry.schedule(after: .milliseconds(Int64(effect.afterMs ?? 0))) { @MainActor [weak self, probe] in
                    self?.handle(.init(kind: "retryFired"))
                    probe.fired()
                }
            case "cancelRetry": retry.cancel()
            case "scheduleCooldown":
                cooldown.schedule(after: .milliseconds(Int64(effect.afterMs ?? 0))) { @MainActor [weak self, probe] in
                    self?.handle(.init(kind: "cooldownFired"))
                    probe.fired()
                }
            case "cancelCooldown": cooldown.cancel()
            default: assertionFailure("cloud.link_step effect \(effect.kind)")
            }
        }
        return sync
    }

    /// The `renew` effect: lease work on `current`, whose outcome steps `renewed`.
    private func renew(_ effect: LinkEffect, on current: Link) {
        guard let endpoint = current.endpoint else { return }
        let reason = effect.reason ?? "missing"
        let answering = effect.answering
        probe.setLeasing(Int(state.leasing))
        lease.renew(endpoint, reason: reason, server: current.server,
                    expectedUserID: { [source] in source.accountID }) { [weak self, source] outcome in
            guard let self else {
                if case .leased(let subject, _) = outcome { source.leaseRenewed(subject: subject) }
                return
            }
            let event = LinkEvent(kind: "renewed", link: WireLink(current), outcome: WireOutcome(outcome),
                                  reason: reason, answering: answering)
            run(step(event), links: [current])
            probe.setLeasing(Int(state.leasing))
        }
    }

    private func cloudIdentity(_ identity: WireIdentity) -> CloudIdentity {
        CloudIdentity(stackUserID: identity.stackUserId, displayName: identity.displayName, localID: localID,
                      stackProjectID: identity.selfHosted ? nil : stackProjectID)
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

// The JSON of `cloud.link_step` (cmux-home-rules `cloud/link.rs`).

/// `Link`: two are equal when all but `hasEndpoint` match.
private nonisolated struct WireLink: Codable, Equatable {
    struct Server: Codable, Equatable {
        var kind: String
        var url: String?
    }

    var hasEndpoint: Bool
    var id: String?
    var userId: String?
    var displayName: String
    var server: Server

    init(_ link: HomeCloudLink.Link) {
        hasEndpoint = link.endpoint != nil
        id = link.id.map { "\($0)" }
        userId = link.userID
        displayName = link.displayName
        switch link.server {
        case .hosted: server = Server(kind: "hosted")
        case .selfHosted(let url): server = Server(kind: "selfHosted", url: url.absoluteString)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.userId == rhs.userId && lhs.displayName == rhs.displayName && lhs.server == rhs.server
    }
}

/// `Outcome`.
private nonisolated struct WireOutcome: Codable {
    struct Info: Codable {
        var userId: String
        var login: String
        var displayName: String?
    }

    var kind: String
    var subject: String?
    var expiresAt: UInt64?
    var info: Info?

    @MainActor init(_ outcome: HomeCloudLease.Outcome) {
        switch outcome {
        case .leased(let subject, let expiresAt): kind = "leased"; self.subject = subject; self.expiresAt = expiresAt
        case .selfHosted(let info):
            kind = "selfHosted"
            self.info = Info(userId: info.userID, login: info.login, displayName: info.displayName)
        case .signedOut: kind = "signedOut"
        case .failed: kind = "failed"
        case .superseded: kind = "superseded"
        }
    }
}

/// `Identity`.
private nonisolated struct WireIdentity: Codable {
    var stackUserId: String
    var displayName: String
    var selfHosted: Bool
}

/// `State`, kept between steps.
private nonisolated struct LinkState: Codable {
    struct Cooldown: Codable {
        var phase: String
        var restMs: UInt64?
        var proven: Bool?
    }

    var last: WireLink?
    var leasing: UInt32 = 0
    var retryDelayMs: UInt64?
    var retryReason: String?
    var leasedExpiry: UInt64?
    var replacedExpiries: [UInt64]?
    var forcedWaitMs: UInt64?
    var cooldown: Cooldown?
    var pendingForced: String?
}

/// `Event`.
private nonisolated struct LinkEvent: Encodable {
    var kind: String
    var link: WireLink?
    var outcome: WireOutcome?
    var reason: String?
    var expiresAt: UInt64?
    var answering: UInt64?
}

private nonisolated struct LinkRequest: Encodable {
    var state: LinkState
    var event: LinkEvent
}

/// `Effect`.
private nonisolated struct LinkEffect: Decodable {
    var kind: String
    var identity: WireIdentity?
    var commands: String?
    var link: WireLink?
    var leased: Bool?
    var expectedUserId: String?
    var reason: String?
    var answering: UInt64?
    var subject: String?
    var afterMs: UInt64?
}

private nonisolated struct LinkReply: Decodable {
    var state: LinkState
    var effects: [LinkEffect]
}
