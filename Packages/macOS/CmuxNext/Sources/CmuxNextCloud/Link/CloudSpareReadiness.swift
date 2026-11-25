import Foundation
import os

/// Leo, Cloud V0 item 1 ("A chat starts in a few seconds: ready spare"): the person's warm spare made ready in this
/// app run before any claim, so the start that claims it has little left to do but open its chat. On a warm's answer
/// (``CloudSpareWarm``) or the platform's `cloud.spare.ready` (``CloudMachineWire/onSpareReady``), ``prime(_:team:dials:)``
/// keys the spare's acpmux for remote approvals (the start's own keyed restart, done ahead: an unclaimed spare's
/// creator is the person, all the owner check asks) and starts its carrier link beside it. A prime from the warm
/// or from a compose's reserve (the person is about to start a chat, and the service keeps the machine running for
/// it) also dials the machine on that link: the first dial of a machine took about 3 s on 2026-11-19, a stream on a session already dialed 0.05 to
/// 0.2 s. A start on a machine this app run keyed skips its approvals step (``isKeyed(_:scope:instance:)``), and the
/// session made for the claimed machine takes the link that is already up (``link(for:team:)``). Once keyed, the spare's
/// model-route report is read too, so the route check of the start that claims it runs no command on the machine
/// (``takeRouteReport(_:scope:instance:)``; 1.9 to 2.5 s of each start, 2026-11-21).
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
        /// `machine`'s model-route report as its start's check would read it now (the App's `CloudMachineRoute.report()`:
        /// one command on the machine), nil when it has none worth keeping. Nil here: no report is read ahead.
        public var route: (@MainActor (_ machine: String) async -> String?)?
        /// Makes the reserved folder of `machine`'s first home chat and warms its agent there (acpmux `warm-home`), after
        /// the machine is keyed (the keyed start restarts the agent service, which would end an earlier warm): whether the
        /// agent is ready. The chat that claims the machine takes that folder and that agent, so its start has no agent
        /// boot left (about 3.5 s, 2026-11-24). Nil here: nothing is warmed ahead.
        public var warm: (@MainActor (_ machine: String) async -> Bool)?

        public init(scope: @escaping @MainActor () -> Scope, key: @escaping @MainActor (String, Scope) async -> String?,
                    keyedInstance: @escaping @MainActor (String) -> String?, link: @escaping @MainActor (String, String?) -> SpareLink?,
                    team: @escaping @MainActor () async -> String?, route: (@MainActor (String) async -> String?)? = nil,
                    warm: (@MainActor (String) async -> Bool)? = nil) {
            (self.scope, self.key, self.keyedInstance, self.link, self.team, self.route, self.warm) = (scope, key, keyedInstance, link, team, route, warm)
        }
    }

    /// A spare's carrier link made ahead of its session: the `carrier serve` the session would make, on a socket of
    /// its own (so a session that does not take it never shares its socket), with its fence and its stop.
    public struct SpareLink: Sendable {
        public let serve: CloudCarrierServe
        let fenced: @Sendable () -> Bool
        let up: @Sendable () async -> Bool
        /// Dials the machine once the link is up (``CloudCarrierServe/dialAhead(limit:keep:)``): whether it connected.
        let dial: @Sendable () async -> Bool
        let end: @Sendable () async -> Void

        /// How long a prime waits for its dial's answer; a dial that takes longer goes on in the serve.
        public static let dialWait: Duration = .seconds(20)
        /// How long the session a dial made is held for a claim: ``CloudSpareReadiness/linkKept`` (600 s) less the two
        /// idle minutes the serve then keeps it itself, so it is closed about when its link is past its keep (the
        /// service may have paused the spare by then, and a session to a paused machine only delays the next connect).
        public static let dialKept: Duration = .seconds(480)

        /// The serve of `connector` (the session's own, as `CloudService.addSession` makes it), on its spare socket.
        public init(spare connector: CloudCarrierDial.Connector, paths: CloudPaths) {
            let serve = CloudCarrierServe(connector: connector, socket: paths.linkSocket(machineID: "spare:" + connector.dial.machine))
            self.init(serve: serve, fenced: { connector.isFenced }, up: { (try? await serve.socketPath()) != nil },
                      dial: { await serve.dialAhead(limit: Self.dialWait, keep: Self.dialKept) }, end: { await serve.stop() })
        }

        init(serve: CloudCarrierServe, fenced: @escaping @Sendable () -> Bool, up: @escaping @Sendable () async -> Bool,
             dial: @escaping @Sendable () async -> Bool, end: @escaping @Sendable () async -> Void) {
            (self.serve, self.fenced, self.up, self.dial, self.end) = (serve, fenced, up, dial, end)
        }
    }

    /// How long a link made ahead is kept for a claim: the platform's warm of an unclaimed spare from one intent
    /// (`SPARE_WARM_MS`, 10 minutes). Past it the next prime or take ends it; the next warm makes another.
    public static let linkKept: Duration = .seconds(600)

    private struct Keyed { let scope: Scope; let instance: String }
    /// A model-route report read ahead: under the daemon run `instance`, for `scope`, kept until `until`.
    private struct Routed { let scope: Scope; let instance: String; let until: ContinuousClock.Instant; let report: String }
    /// Where a held link's dial ahead stands: one dial per link, never asked twice.
    private enum Dial: String { case notAsked = "not dialed", running = "dialing", connected = "dialed", failed = "its dial did not connect" }
    private struct Held {
        let scope: Scope
        let team: String?
        let until: ContinuousClock.Instant
        let link: SpareLink
        var isUp = false
        var dial = Dial.notAsked
    }

    private let dependencies: Dependencies
    /// The account's one spare-warm gate: a Cmd-Tab burst spawns one CLI process (hq#8747).
    public let warmGate = CloudSpareWarmGate()
    private var keyed: [String: Keyed] = [:]
    private var routes: [String: Routed] = [:]
    /// When a route read ahead of `machine` last gave no report: not read again for ``keyRetry``.
    private var routeMissed: [String: ContinuousClock.Instant] = [:]
    /// The daemon run each machine's first home chat was warmed under (``Dependencies/warm``): one warm per run.
    private var warmed: [String: String] = [:]
    /// When a warm ahead of `machine` last did not leave its agent ready: not tried again for ``keyRetry``.
    private var warmMissed: [String: ContinuousClock.Instant] = [:]
    private var links: [String: Held] = [:]
    /// The prime running for each machine, with the ``resets`` it started under: one from before a reset writes
    /// nothing, so a prime after that reset starts its own. `dials`: it dials its link; `id` tells it from a later one.
    private var primes: [String: (resets: Int, dials: Bool, id: Int, task: Task<Void, Never>)] = [:]
    private var lastPrime = 0
    /// Machines whose session asked for its link while a prime still ran for them: the primes running for it make no
    /// link after that.
    private var asked: Set<String> = []
    /// When a key ahead of `machine` last did not key it: not tried again for ``keyRetry``, so a spare whose daemon is
    /// busy or too old is not read (or restarted) on every app activation.
    private var keyMissed: [String: ContinuousClock.Instant] = [:]
    /// Counts ``reset()``: a prime that started before one records nothing after it, neither a key nor a link.
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
    /// `dials`: a prime that also dials the machine on the link: the warm's and a reserve's (the person is about to
    /// start a chat). Two dialing primes of one machine name one team, so the second joins the first. One that joins
    /// a prime that does not dial links and dials beside it.
    public func prime(_ machine: String, team: String? = nil, dials: Bool = false) {
        let scope = dependencies.scope()
        sweep()
        let resets = resets
        guard Self.signedIn(scope), !machine.isEmpty else { return }
        let running = primes[machine].flatMap { $0.resets == resets ? $0 : nil }
        if let running, running.dials || !dials { return }
        lastPrime += 1
        let id = lastPrime
        if running == nil { asked.remove(machine) }
        // task-owner: primes[machine]; one bounded prime (the keyed start's and the link's own deadlines end it), removed when it ends
        primes[machine] = (resets, dials, id, Task { [weak self] in
            if let running {
                await self?.linkAhead(machine, team: team, scope: scope, resets: resets, dials: dials)
                await running.task.value
            } else {
                await self?.primed(machine, team: team, scope: scope, resets: resets, dials: dials)
            }
            if self?.primes[machine]?.id == id {
                self?.primes[machine] = nil
                self?.asked.remove(machine)
            }
        })
    }

    /// Waits for `machine`'s prime to end (tests).
    public func settled(_ machine: String) async { await primes[machine]?.task.value }

    /// The link made ahead for `machine`, for its session to take, when it is still for the scope signed in, `team` and
    /// not past ``linkKept``; else nil, and a link that no longer fits is ended. Taken once.
    public func link(for machine: String, team: String?) -> CloudCarrierServe? {
        // Its session links now, with this link or its own: a prime still running for it (one that joined may still
        // read the team) makes no other.
        if primes[machine] != nil { asked.insert(machine) }
        guard let held = links.removeValue(forKey: machine) else { return nil }
        let scope = dependencies.scope()
        guard fits(held, scope: scope), held.team == team else {
            let why = held.scope != scope ? "the account changed since"
                : now() >= held.until ? "it is past its keep"
                : held.link.fenced() ? "its account ended"
                : "it was made for team \(held.team ?? "none") and the machine is in \(team ?? "none")"
            Self.log.notice("cloud spare \(machine, privacy: .public): the link made ahead is ended, not taken: \(why, privacy: .public)")
            end(held.link)
            return nil
        }
        Self.log.notice("cloud spare \(machine, privacy: .public): its session takes the link made ahead (\(held.dial.rawValue, privacy: .public))")
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
        routes = [:]
        routeMissed = [:]
        warmed = [:]
        warmMissed = [:]
        asked = []
        resets += 1
    }

    /// The model-route report read ahead on `machine` (``Dependencies/route``), for the route check of the start that
    /// claims it: only for the scope it was read in, while the daemon run this app keyed is still `instance` (the run
    /// the report was read under) and not past ``linkKept``. That start then runs no command on the machine for a
    /// report that says its chat starts. Taken once, like the link: nobody uses an unclaimed spare, but a chat on a
    /// claimed machine can change what the report says (a login removed, its agent service restarted), so every later
    /// start there reads its own. An entry that does not fit is dropped too.
    public func takeRouteReport(_ machine: String, scope: Scope, instance: String?) -> String? {
        guard let entry = routes.removeValue(forKey: machine), fits(entry, scope: scope, instance: instance) else { return nil }
        return entry.report
    }

    /// Whether a report read ahead for `machine` waits for its start (tests and diagnostics).
    public func holdsRouteReport(_ machine: String) -> Bool {
        routes[machine].map { fits($0, scope: dependencies.scope(), instance: dependencies.keyedInstance(machine)) } ?? false
    }

    private func fits(_ entry: Routed, scope: Scope, instance: String?) -> Bool {
        Self.signedIn(scope) && entry.scope == scope && instance != nil && entry.instance == instance && now() < entry.until
    }

    private func primed(_ machine: String, team: String?, scope: Scope, resets: Int, dials: Bool) async {
        async let linked: Void = linkAhead(machine, team: team, scope: scope, resets: resets, dials: dials)
        await keyAhead(machine, scope: scope, resets: resets)
        async let warm: Void = warmAhead(machine, scope: scope, resets: resets)
        await routeAhead(machine, scope: scope, resets: resets)
        await warm
        await linked
    }

    /// Warms the first home chat of a keyed spare (``Dependencies/warm``), under the daemon run that holds the key: once per
    /// run; one that did not leave its agent ready waits ``keyRetry``. `resets`: as ``keyAhead(_:scope:resets:)``.
    private func warmAhead(_ machine: String, scope: Scope, resets: Int) async {
        guard resets == self.resets, let warm = dependencies.warm, let instance = dependencies.keyedInstance(machine),
              isKeyed(machine, scope: scope, instance: instance), warmed[machine] != instance else { return }
        if let missed = warmMissed[machine], now() < missed.advanced(by: Self.keyRetry) { return }
        warmMissed[machine] = nil
        // Marked before the command runs: a second prime meanwhile warms nothing again.
        warmed[machine] = instance
        let ready = await warm(machine)
        guard resets == self.resets else { return }
        guard ready, dependencies.scope() == scope, dependencies.keyedInstance(machine) == instance else {
            if warmed[machine] == instance { warmed[machine] = nil }
            warmMissed[machine] = now()
            Self.log.info("cloud spare \(machine, privacy: .public): no home chat warmed ahead (not ready, or its agent service or the account changed); the start starts its agent")
            return
        }
        Self.log.info("cloud spare \(machine, privacy: .public): home chat warmed ahead")
    }

    /// Whether `machine`'s first home chat was warmed under daemon run `instance` (tests and diagnostics).
    public func holdsHomeWarm(_ machine: String, instance: String) -> Bool { warmed[machine] == instance }

    /// Reads the spare's model-route report once it is keyed, under the daemon run that holds the key: the keyed start
    /// restarts the machine's agent service, so a report from before it is not that run's. One read per run; a read
    /// that gave none waits ``keyRetry``. `resets`: as ``keyAhead(_:scope:resets:)``.
    private func routeAhead(_ machine: String, scope: Scope, resets: Int) async {
        guard resets == self.resets, let route = dependencies.route, let instance = dependencies.keyedInstance(machine),
              isKeyed(machine, scope: scope, instance: instance) else { return }
        // Held for this scope and run: kept. One that no longer fits (another run or account, past its keep) is read again.
        if let held = routes[machine], fits(held, scope: scope, instance: instance) { return }
        if let missed = routeMissed[machine], now() < missed.advanced(by: Self.keyRetry) { return }
        routeMissed[machine] = nil
        let report = await route(machine)
        // Forgotten while it ran: nothing of this run is written back.
        guard resets == self.resets else { return }
        // No report, another account, or another daemon run since (a restart under the read): not this run's report.
        guard let report, dependencies.scope() == scope, dependencies.keyedInstance(machine) == instance else {
            routeMissed[machine] = now()
            Self.log.info("cloud spare \(machine, privacy: .public): no model route read ahead (no report, or its agent service or the account changed); the start reads it")
            return
        }
        routes[machine] = Routed(scope: scope, instance: instance, until: now().advanced(by: Self.linkKept), report: report)
        Self.log.info("cloud spare \(machine, privacy: .public): model route read ahead")
    }

    /// `resets` is the count its prime started under: forgotten since (Cloud turned off, signed out), it keys nothing.
    private func keyAhead(_ machine: String, scope: Scope, resets: Int) async {
        guard resets == self.resets, !isKeyed(machine, scope: scope, instance: dependencies.keyedInstance(machine)) else { return }
        if let missed = keyMissed[machine], now() < missed.advanced(by: Self.keyRetry) { return }
        keyMissed[machine] = nil
        let instance = await dependencies.key(machine, scope)
        // Forgotten while it ran: nothing of this run is written back.
        guard resets == self.resets else { return }
        guard let instance, dependencies.scope() == scope else {
            keyMissed[machine] = now()
            Self.log.info("cloud spare \(machine, privacy: .public): not keyed ahead (its daemon is not idle or not up yet, or the account changed); the start keys it")
            return
        }
        keyed[machine] = Keyed(scope: scope, instance: instance)
        routeMissed[machine] = nil // a new daemon run: a read that gave no report under the one before does not hold this one's
        Self.log.info("cloud spare \(machine, privacy: .public): keyed ahead for approvals")
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.spare")

    private func linkAhead(_ machine: String, team named: String?, scope: Scope, resets: Int, dials: Bool) async {
        let team: String?
        if let named { team = named } else { team = await dependencies.team() } // read beside the keying, never ahead of it
        // Forgotten since its prime (the scope may still be the same one: Cloud turned off): no link is made or held.
        // Or its session asked for the link while the team was read, and links its own: a second serve nobody takes
        // is not made.
        guard resets == self.resets, !asked.contains(machine), dependencies.scope() == scope else { return }
        // Held and fit: kept. A prime that dials replaces a link made for another team than the one it names; any
        // other prime, and one whose team could not be read, keeps what is held.
        let kept = links[machine].map { fits($0, scope: scope) && ($0.team == team || !dials || team == nil) } ?? false
        if !kept {
            if let stale = links.removeValue(forKey: machine) { end(stale.link) }
            guard let link = dependencies.link(machine, team) else { return }
            links[machine] = Held(scope: scope, team: team, until: now().advanced(by: Self.linkKept), link: link)
        }
        guard let link = links[machine]?.link else { return }
        if links[machine]?.isUp != true {
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
            // Two primes may wait for one link to come up: the first back records it.
            if links[machine]?.isUp != true {
                links[machine]?.isUp = true
                Self.log.info("cloud spare \(machine, privacy: .public): linked ahead")
            }
        }
        guard dials, links[machine]?.dial == .notAsked else { return }
        links[machine]?.dial = .running
        let began = now()
        let dialed = await link.dial()
        // Taken, swept or reset while it dialed: the session's own connect joins the dial or makes its own.
        guard links[machine]?.link.serve === link.serve else { return }
        links[machine]?.dial = dialed ? .connected : .failed
        let ms = Int(began.duration(to: now()) / .milliseconds(1))
        if dialed {
            Self.log.notice("cloud spare \(machine, privacy: .public): dialed ahead in \(ms) ms")
        } else {
            Self.log.notice("cloud spare \(machine, privacy: .public): not dialed ahead after \(ms) ms (refused, or no answer yet); the start's connect dials")
        }
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

    /// Whether the account scope `now` (the App's `"user\0team"`, nil signed out) is a sign-in after `previous` (the scope
    /// before it, `.none` before the first): the person's spare is warmed then, as an activation signed in warms it, so
    /// it is keyed and linked from the sign-in on. An activation that came while signed out (a launch whose sign-in
    /// lands a few seconds later) warmed nothing, and the first start's own warm was the first: its key ahead (a status
    /// read, the keyed restart and its proof, 3 to 4.5 s from the warm's answer) then ended 1 to 2 s after the claim
    /// connected, and the start's approvals step waited it out.
    public nonisolated static func warmsAtSignIn(previous: String??, now: String?) -> Bool {
        guard let now else { return false }
        return (previous ?? nil) != now
    }

    /// A scope with a user: signed in (the team may be unset).
    private static func signedIn(_ scope: Scope) -> Bool { (scope.first ?? nil)?.isEmpty == false }
}
