import Foundation
import os

/// Leo, Cloud V0 item 1 ("A chat starts in a few seconds: ready spare"): the person's warm spare made ready in this
/// app run before any claim, so the start that claims it has little left to do but open its chat. On a warm's answer
/// (``CloudSpareWarm``) or the platform's `cloud.spare.ready` (``CloudMachineWire/onSpareReady``), ``prime(_:team:)``
/// keys the spare's acpmux for remote approvals (the start's own keyed restart, done ahead: an unclaimed spare's
/// creator is the person, all the owner check asks) and starts its carrier link beside it. A start on a machine this
/// app run keyed skips its approvals step (``isKeyed(_:scope:instance:)``), and the session made for the claimed
/// machine takes the link that is already up (``link(for:team:)``).
///
/// Memory only, like the key itself: an app restart starts with nothing keyed. Every entry belongs to one scope, the
/// user and team signed in when it was made: after a sign-out or an account or team switch it reads as absent (and is
/// dropped), and a prime whose scope changed while it ran records nothing. The keyed start itself
/// (``Dependencies/key``) runs only on a daemon that says it is idle, so never under an agent that runs.
@MainActor
public final class CloudSpareReadiness {
    /// The user and team signed in (the App's `CloudService.account`).
    public typealias Scope = [String?]

    /// What the App supplies: who is signed in, the keyed start, the key's daemon run, the link's carrier, and the team a
    /// spare is in.
    public struct Dependencies {
        /// The user and team signed in now.
        public var scope: @MainActor () -> Scope
        /// The keyed start on `machine` while `scope` is still signed in, only when its daemon says it is idle (no
        /// agent runs). The daemon run that proved it holds the new key, nil when nothing was keyed.
        public var key: @MainActor (_ machine: String, _ scope: Scope) async -> String?
        /// The daemon run of `machine` that holds this app's key now, nil for none.
        public var keyedInstance: @MainActor (_ machine: String) -> String?
        /// `machine`'s carrier link in `team`, not started yet; nil when there is none to make.
        public var link: @MainActor (_ machine: String, _ team: String?) -> SpareLink?
        /// The team the person's spare, its create and the record the claim answers are in: the install token's team, never
        /// the App's active team (a member of a shared team has an active team that is not the install token's). A link
        /// made for another team than the record's is ended at the claim, not taken. Nil when it cannot be read.
        public var team: @MainActor () async -> String?

        public init(scope: @escaping @MainActor () -> Scope, key: @escaping @MainActor (String, Scope) async -> String?,
                    keyedInstance: @escaping @MainActor (String) -> String?, link: @escaping @MainActor (String, String?) -> SpareLink?,
                    team: @escaping @MainActor () async -> String?) {
            (self.scope, self.key, self.keyedInstance, self.link, self.team) = (scope, key, keyedInstance, link, team)
        }
    }

    /// A spare's carrier link made ahead of its session: the `carrier serve` the session would make, on a socket of
    /// its own (so a session that does not take it never shares its socket), with its fence and its stop.
    public struct SpareLink: Sendable {
        public let serve: CloudCarrierServe
        let fenced: @Sendable () -> Bool
        let up: @Sendable () async -> Bool
        let end: @Sendable () async -> Void

        /// The serve of `connector` (the session's own, as `CloudService.addSession` makes it), on its spare socket.
        public init(spare connector: CloudCarrierDial.Connector, paths: CloudPaths) {
            let serve = CloudCarrierServe(connector: connector, socket: paths.linkSocket(machineID: "spare:" + connector.dial.machine))
            self.init(serve: serve, fenced: { connector.isFenced }, up: { (try? await serve.socketPath()) != nil }, end: { await serve.stop() })
        }

        init(serve: CloudCarrierServe, fenced: @escaping @Sendable () -> Bool, up: @escaping @Sendable () async -> Bool,
             end: @escaping @Sendable () async -> Void) {
            (self.serve, self.fenced, self.up, self.end) = (serve, fenced, up, end)
        }
    }

    /// How long a link made ahead is kept for a claim: the platform's warm of an unclaimed spare from one intent
    /// (`SPARE_WARM_MS`, 10 minutes). Past it the next prime or take ends it; the next warm makes another.
    public static let linkKept: Duration = .seconds(600)

    private struct Keyed { let scope: Scope; let instance: String }
    private struct Held { let scope: Scope; let team: String?; let until: ContinuousClock.Instant; let link: SpareLink }

    private let dependencies: Dependencies
    private var keyed: [String: Keyed] = [:]
    private var links: [String: Held] = [:]
    private var primes: [String: Task<Void, Never>] = [:]
    /// Machines whose session asked for a link while their prime still read the team: that prime links nothing.
    private var asked: Set<String> = []
    /// When a key ahead of `machine` last did not key it: not tried again for ``keyRetry``, so a spare whose daemon is
    /// busy or too old is not read (or restarted) on every app activation.
    private var keyMissed: [String: ContinuousClock.Instant] = [:]
    /// Counts ``reset()``: a key ahead that was running across one records nothing.
    private var resets = 0
    /// How long after a key ahead that keyed nothing the next one waits.
    public static let keyRetry: Duration = .seconds(60)
    public var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init(_ dependencies: Dependencies) { self.dependencies = dependencies }

    /// Whether this app run keyed `machine` for `scope` and the key's daemon run is still `instance` (the one that
    /// holds this app's key now): the start's approvals step has nothing to do. An entry of another scope or run is
    /// dropped.
    public func isKeyed(_ machine: String, scope: Scope, instance: String?) -> Bool {
        guard let entry = keyed[machine] else { return false }
        guard Self.signedIn(scope), entry.scope == scope, let instance, entry.instance == instance else {
            keyed[machine] = nil
            return false
        }
        return true
    }

    /// Makes `machine` ready for a claim in the scope signed in now: keyed and linked, each once. Never awaited by its
    /// caller; a second prime of the same machine while one runs joins it. `team`: the spare's team as the platform
    /// named it (a warm's answer); nil reads it from ``Dependencies/team``, so every caller links in the same team.
    public func prime(_ machine: String, team: String? = nil) {
        let scope = dependencies.scope()
        sweep()
        guard Self.signedIn(scope), !machine.isEmpty, primes[machine] == nil else { return }
        // task-owner: primes[machine]; one bounded prime (the keyed start's and the link's own deadlines end it), removed when it ends
        asked.remove(machine)
        primes[machine] = Task { [weak self] in
            await self?.primed(machine, team: team, scope: scope)
            self?.primes[machine] = nil
            self?.asked.remove(machine)
        }
    }

    /// Waits for `machine`'s prime to end (tests).
    public func settled(_ machine: String) async { await primes[machine]?.value }

    /// The link made ahead for `machine`, for its session to take, when it is still for the scope signed in, `team` and
    /// not past ``linkKept``; else nil, and a link that no longer fits is ended. Taken once.
    public func link(for machine: String, team: String?) -> CloudCarrierServe? {
        guard let held = links.removeValue(forKey: machine) else {
            if primes[machine] != nil { asked.insert(machine) }
            return nil
        }
        guard fits(held, scope: dependencies.scope()), held.team == team else {
            let why = held.team == team ? "it expired, was fenced or the account changed" : "it was made for team \(held.team ?? "none"), the record is in \(team ?? "none")"
            Self.log.info("cloud spare \(machine, privacy: .public): link ahead not taken (\(why, privacy: .public)); the start links it")
            end(held.link)
            return nil
        }
        return held.link.serve
    }

    /// Whether a link made ahead for `machine` waits for its session (tests and diagnostics).
    public func holdsLink(_ machine: String) -> Bool { links[machine].map { fits($0, scope: dependencies.scope()) } ?? false }

    /// Forgets everything: each link made ahead ends, and no machine reads as keyed.
    public func reset() {
        for held in links.values { end(held.link) }
        links = [:]
        keyed = [:]
        keyMissed = [:]
        asked = []
        resets += 1
    }

    private func primed(_ machine: String, team: String?, scope: Scope) async {
        async let linked: Void = linkAhead(machine, team: team, scope: scope)
        await keyAhead(machine, scope: scope)
        await linked
    }

    private func keyAhead(_ machine: String, scope: Scope) async {
        guard !isKeyed(machine, scope: scope, instance: dependencies.keyedInstance(machine)) else { return }
        if let missed = keyMissed[machine], now() < missed.advanced(by: Self.keyRetry) { return }
        keyMissed[machine] = nil
        let resets = resets
        let instance = await dependencies.key(machine, scope)
        // Forgotten meanwhile (Cloud turned off, signed out): nothing of this run is written back.
        guard resets == self.resets else { return }
        guard let instance, dependencies.scope() == scope else {
            keyMissed[machine] = now()
            Self.log.info("cloud spare \(machine, privacy: .public): not keyed ahead (its daemon is not idle or not up yet, or the account changed); the start keys it")
            return
        }
        keyed[machine] = Keyed(scope: scope, instance: instance)
        Self.log.info("cloud spare \(machine, privacy: .public): keyed ahead for approvals")
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.spare")

    private func linkAhead(_ machine: String, team named: String?, scope: Scope) async {
        let team: String?
        if let named { team = named } else { team = await dependencies.team() } // read beside the keying, never ahead of it
        // Its session asked for the link while the team was read, and links its own: a second serve nobody takes is not dialed.
        guard !asked.contains(machine), dependencies.scope() == scope else { return }
        if let held = links[machine], fits(held, scope: scope), held.team == team { return }
        if let stale = links.removeValue(forKey: machine) { end(stale.link) }
        guard let link = dependencies.link(machine, team) else { return }
        links[machine] = Held(scope: scope, team: team, until: now().advanced(by: Self.linkKept), link: link)
        let up = await link.up()
        // No longer held here: a session took it while it came up (its own connect waits on the same serve), or a
        // sweep, a take or a reset ended it. Either way it is not this prime's to end.
        guard links[machine]?.link.serve === link.serve else { return }
        // Down, or made for a scope no longer signed in: ended, and nothing waits for a session.
        guard up, dependencies.scope() == scope else {
            links[machine] = nil
            end(link)
            Self.log.info("cloud spare \(machine, privacy: .public): no link ahead (it did not come up, or the account changed); the start links it")
            return
        }
        Self.log.info("cloud spare \(machine, privacy: .public): linked ahead")
    }

    private func fits(_ held: Held, scope: Scope) -> Bool { held.scope == scope && now() < held.until && !held.link.fenced() }

    /// Ends the links that no longer fit the scope signed in or outlived ``linkKept``.
    private func sweep() {
        let scope = dependencies.scope()
        for (machine, held) in links where !fits(held, scope: scope) {
            links[machine] = nil
            end(held.link)
        }
    }

    private func end(_ link: SpareLink) {
        // task-owner: none; one stop line to the serve's supervisor, which ends its child
        Task { await link.end() }
    }

    /// A scope with a user: signed in (the team may be unset).
    private static func signedIn(_ scope: Scope) -> Bool { (scope.first ?? nil)?.isEmpty == false }
}
