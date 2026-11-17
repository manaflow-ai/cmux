import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// iOS connectivity and reliability matrix: the phone's side.
//
// One `@Test` per cell of `cmux-next-ios/reliability-matrix/cells.json`; the
// protocol-level cells (session list scale, MB tool output, backlog after an
// outage, daemon restart, a sleeping Mac's silent link) are in
// `rust/crates/cmux-mobile-host/tests/reliability_matrix.rs`, and
// `scripts/ci/ios_reliability_matrix.py` joins both into one table.
//
// The phone's connection is `LinkMachine` (events in, effects out) run by
// `LinkController`. Timeline cells drive the machine on a virtual clock
// against a scripted network and Mac, so an 8 hour outage takes
// microseconds and every run is the same. Each asserts:
// - reconnected within a bound after the network or Mac is back;
// - the line the person sees (`statusLine`) says what is going on;
// - the degenerate variant (hours instead of seconds) is within 1.2x of
//   the small one.
// Controller cells (token refresh, memory warning) run the real controller
// with a scripted dialer.

/// The degenerate bound shared with the Rust cells.
private let godRatio = 1.2

private func withinGodBound(small: Duration, god: Duration) -> Bool {
    // 50 ms: below it a difference is one dial's jitter, not growth.
    god.seconds <= small.seconds * godRatio + 0.05
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

private func report(_ cell: String, _ variant: String, _ fields: [String: Any]) {
    var line = fields
    line["cell"] = cell
    line["variant"] = variant
    if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print("MATRIX \(text)")
    }
}

/// What the world does to a dial at a moment of virtual time.
private struct World {
    /// Whether a dial started at `t` reaches the Mac, and how long it takes
    /// (a refused dial fails after its time too).
    var dial: (_ t: Duration) -> (ok: Bool, after: Duration, reason: String)
}

/// Runs a `LinkMachine` on virtual time: dials resolve by `world`, retries
/// fire when due, and `external` events (network back, presence, scene
/// changes) arrive at their times. Records every phase with its time.
private struct Timeline {
    var machine = LinkMachine(transport: .wireGuard)
    var now: Duration = .zero
    var phases: [(at: Duration, phase: LinkMachine.Phase)] = []
    var dials = 0
    private var pending: [(at: Duration, event: LinkMachine.Event)] = []

    mutating func run(world: World, external: [(Duration, LinkMachine.Event)], until end: Duration) {
        pending = external.map { (at: $0.0, event: $0.1) }
        while true {
            pending.sort { $0.at < $1.at }
            guard let next = pending.first, next.at <= end else { break }
            pending.removeFirst()
            now = next.at
            apply(next.event, world: world)
        }
        now = end
    }

    private mutating func apply(_ event: LinkMachine.Event, world: World) {
        let effects = machine.handle(event)
        phases.append((now, machine.phase))
        for effect in effects {
            switch effect {
            case .dial(let generation, _, _):
                dials += 1
                let outcome = world.dial(now)
                let result: LinkMachine.Event = outcome.ok
                    ? .dialSucceeded(generation: generation, path: .direct)
                    : .dialFailed(generation: generation, reason: outcome.reason)
                pending.append((now + outcome.after, result))
            case .scheduleRetry(let generation, let after):
                pending.append((now + after, .retryDue(generation: generation)))
            case .close, .probe, .quickProbe:
                break
            }
        }
    }

    /// When the machine was first connected at or after `t`.
    func connected(after t: Duration) -> Duration? {
        phases.first { $0.at >= t && $0.phase.isConnected }?.at
    }

    /// Every status line shown in `[from, to)`: the phase after the events
    /// at `from` (a link dropped at `from` never shows "Connected" in the
    /// window), then every later one before `to`.
    func statusLines(from: Duration, to: Duration, mac: String = "Studio") -> Set<String> {
        var lines = Set<String>()
        if let first = phases.last(where: { $0.at <= from })?.phase, let line = first.statusLine(macName: mac) {
            lines.insert(line)
        }
        for (at, phase) in phases where at > from && at < to {
            if let line = phase.statusLine(macName: mac) { lines.insert(line) }
        }
        return lines
    }
}

private let studio = LinkMachine.Target(macID: "m1", name: "Studio", isOnline: true)
private let studioAsleep = LinkMachine.Target(macID: "m1", name: "Studio", isOnline: false)
private let dialTime: Duration = .milliseconds(400)
private let offlineReason = LinkController.reason(LinkError(code: "offline", message: ""))
private let timeoutReason = LinkController.reason(LinkError(code: "timeout", message: ""))

@Suite struct ConnectivityMatrixTests {
    // MARK: Network

    /// The phone loses its network (subway, flight) for 10 s or 8 h (god),
    /// then gets it back; the path monitor's change sends `.networkChanged` after
    /// `networkSettle`. Reconnected within 2 s of the network being back,
    /// "Reconnecting…" while down, and 8 h within 1.2x of 10 s.
    @Test func cellNetworkOfflineThenBack() {
        var results: [Duration] = []
        for (variant, outage) in [("small-10s", Duration.seconds(10)), ("god-8h", Duration.seconds(8 * 3600))] {
            let lost: Duration = .seconds(5)
            let back = lost + outage
            let world = World { t in
                t >= lost && t < back ? (false, .milliseconds(100), "network unreachable") : (true, dialTime, "")
            }
            var timeline = Timeline()
            timeline.run(world: world, external: [
                (.zero, .target(studio)),
                (lost, .linkDropped(generation: 1, reason: "network lost")),
                (back + LinkController.networkSettle, .networkChanged),
            ], until: back + .seconds(60))
            let reconnected = timeline.connected(after: back).map { $0 - back }
            report("network_offline_then_back", variant, [
                "outage_s": outage.seconds, "reconnect_ms": (reconnected?.seconds ?? -1) * 1000, "dials": timeline.dials,
            ])
            #expect(reconnected != nil && reconnected! <= .seconds(2), "\(variant): reconnected \(String(describing: reconnected)) after the network came back")
            #expect(timeline.statusLines(from: lost, to: back) == ["Reconnecting…"], "\(variant): \(timeline.statusLines(from: lost, to: back))")
            // Retries back off: an 8 h outage is not a dial every second.
            #expect(Double(timeline.dials) <= outage.seconds / 15 + 10, "\(variant): \(timeline.dials) dials")
            results.append(reconnected ?? .seconds(3600))
        }
        #expect(withinGodBound(small: results[0], god: results[1]), "8 h outage \(results[1]) vs 10 s \(results[0])")
    }

    /// The network comes back while a retry dial is in flight on the dead
    /// path (a half-dead network: the dial's offer goes nowhere and waits out
    /// its 25 s timeout). The path change must restart it, not leave the
    /// person waiting for that timeout and then a backoff step.
    @Test func cellNetworkBackDuringInflightDial() {
        var results: [Duration] = []
        for (variant, outage) in [("small-10s", Duration.seconds(10)), ("god-8h", Duration.seconds(8 * 3600))] {
            let lost: Duration = .seconds(5)
            let back = lost + outage
            let world = World { t in
                t >= lost && t < back ? (false, .seconds(25), timeoutReason) : (true, dialTime, "")
            }
            var timeline = Timeline()
            timeline.run(world: world, external: [
                (.zero, .target(studio)),
                (lost, .linkDropped(generation: 1, reason: "network lost")),
                (back + LinkController.networkSettle, .networkChanged),
            ], until: back + .seconds(120))
            let reconnected = timeline.connected(after: back).map { $0 - back }
            report("network_back_during_inflight_dial", variant, [
                "outage_s": outage.seconds, "reconnect_ms": (reconnected?.seconds ?? -1) * 1000,
            ])
            #expect(reconnected != nil && reconnected! <= .seconds(2), "\(variant): reconnected \(String(describing: reconnected)) after the network came back")
            results.append(reconnected ?? .seconds(3600))
        }
        #expect(withinGodBound(small: results[0], god: results[1]), "god \(results[1]) vs small \(results[0])")
    }

    /// The network comes back without a path change (a captive portal the
    /// person logs into, a VPN that comes up): only the retry timer redials.
    /// Bounded by the longest backoff step plus a dial.
    @Test func cellNetworkBackWithoutPathChange() {
        var results: [Duration] = []
        for (variant, outage) in [("small-10s", Duration.seconds(10)), ("god-8h", Duration.seconds(8 * 3600))] {
            let lost: Duration = .seconds(5)
            let back = lost + outage
            let world = World { t in
                t >= lost && t < back ? (false, .milliseconds(100), "network unreachable") : (true, dialTime, "")
            }
            var timeline = Timeline()
            timeline.run(world: world, external: [
                (.zero, .target(studio)),
                (lost, .linkDropped(generation: 1, reason: "network lost")),
            ], until: back + .seconds(120))
            let reconnected = timeline.connected(after: back).map { $0 - back }
            let bound = Duration.seconds(LinkMachine(transport: .wireGuard).backoff.max() ?? 30) + dialTime
            report("network_back_without_path_change", variant, [
                "outage_s": outage.seconds, "reconnect_ms": (reconnected?.seconds ?? -1) * 1000, "bound_ms": bound.seconds * 1000,
            ])
            #expect(reconnected != nil && reconnected! <= bound, "\(variant): \(String(describing: reconnected))")
            results.append(reconnected ?? .seconds(3600))
        }
        // Both end on the longest backoff step: the same worst case.
        #expect(results[1] <= Duration.seconds(30) + dialTime)
    }

    /// Wi-Fi to cellular: the link drops when the old path dies; one redial
    /// on the new path. Reconnected within 1 s; never says "Offline".
    @Test func cellNetworkWifiToCellularHandoff() {
        let handoff: Duration = .seconds(5)
        let world = World { _ in (true, dialTime, "") }
        var timeline = Timeline()
        timeline.run(world: world, external: [
            (.zero, .target(studio)),
            (handoff, .linkDropped(generation: 1, reason: "path changed")),
        ], until: .seconds(30))
        let reconnected = timeline.connected(after: handoff).map { $0 - handoff }
        report("network_wifi_to_cellular", "small", ["reconnect_ms": (reconnected?.seconds ?? -1) * 1000, "dials": timeline.dials])
        #expect(reconnected != nil && reconnected! <= .seconds(1))
        #expect(!timeline.statusLines(from: handoff, to: .seconds(30)).contains("Offline"))
        #expect(timeline.dials == 2)
    }

    /// UDP blocked (a hotel or corporate network): the redial with UDP
    /// blocked keeps the same machine path, so the link comes back as a
    /// WireGuard dial over TURN/TLS (link suites: `wireguard_with_udp_blocked_rides_turn_over_tls`).
    /// Here: switching UDP-blocked mode redials once and connects.
    @Test func cellNetworkUDPBlocked() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(studio))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        let effects = machine.handle(.blockUDP(true))
        #expect(effects == [.close, .dial(generation: 2, macID: "m1", transport: .wireGuard)])
        _ = machine.handle(.dialSucceeded(generation: 2, path: .turnTLS))
        report("network_udp_blocked", "small", ["path": "turnTLS"])
        #expect(machine.phase == .connected(.wireGuard, .turnTLS, rttMillis: nil))
    }

    // MARK: App state

    /// Backgrounded for 1 min or 8 h (god), then active: the link kept across
    /// suspension is replaced at once, not probed first. Reconnected within
    /// one dial; 8 h within 1.2x of 1 min.
    @Test func cellAppBackgroundThenForeground() {
        var results: [Duration] = []
        for (variant, away) in [("small-1min", Duration.seconds(60)), ("god-8h", Duration.seconds(8 * 3600))] {
            let world = World { _ in (true, dialTime, "") }
            var timeline = Timeline()
            let leave: Duration = .seconds(5)
            let resume = leave + away
            timeline.run(world: world, external: [
                (.zero, .target(studio)),
                (leave, .background),
                (resume, .resume),
            ], until: resume + .seconds(30))
            let reconnected = timeline.connected(after: resume).map { $0 - resume }
            report("app_background_then_foreground", variant, ["away_s": away.seconds, "reconnect_ms": (reconnected?.seconds ?? -1) * 1000])
            #expect(reconnected != nil && reconnected! <= dialTime + .milliseconds(1))
            results.append(reconnected ?? .seconds(3600))
        }
        #expect(withinGodBound(small: results[0], god: results[1]))
    }

    /// Killed and relaunched: a fresh machine dials at once with no retry
    /// delay, and says "Reconnecting…" (never "Offline") until it is up.
    @Test func cellAppKilledAndRelaunched() {
        let world = World { _ in (true, dialTime, "") }
        var timeline = Timeline()
        timeline.run(world: world, external: [(.zero, .target(studio))], until: .seconds(10))
        let connected = timeline.connected(after: .zero)
        report("app_killed_and_relaunched", "small", ["connect_ms": (connected?.seconds ?? -1) * 1000])
        #expect(connected == dialTime)
        #expect(timeline.statusLines(from: .zero, to: dialTime) == ["Reconnecting…"])
    }

    /// A memory warning while connected gives memory back without touching
    /// the link: still connected, no redial.
    @MainActor @Test func cellAppMemoryWarning() async throws {
        let dialer = ScriptedDialer(outcomes: [.connect])
        let controller = ScriptedDialer.controller(dialer)
        defer { controller.send(.target(nil)) }
        try await eventually { controller.phase.isConnected }
        let pressure = MemoryPressure(observesSystem: false)
        let owner = NSObject()
        var relieved = 0
        pressure.register(owner) { relieved += 1 }
        pressure.relieve()
        try await Task.sleep(for: .milliseconds(50))
        report("app_memory_warning", "small", ["dials": dialer.dials, "relieved": relieved])
        #expect(relieved == 1)
        #expect(controller.phase.isConnected)
        #expect(dialer.dials == 1)
    }

    // MARK: Host side

    /// The Mac sleeps (presence goes offline) for 1 min or 8 h (god), then
    /// wakes. While asleep: "Offline" and no dials at all. After wake:
    /// connected within one dial; 8 h within 1.2x of 1 min.
    @Test func cellHostMacAsleepThenWakes() {
        var results: [Duration] = []
        for (variant, asleep) in [("small-1min", Duration.seconds(60)), ("god-8h", Duration.seconds(8 * 3600))] {
            let sleep: Duration = .seconds(5)
            let wake = sleep + asleep
            let world = World { t in t >= sleep && t < wake ? (false, .seconds(25), timeoutReason) : (true, dialTime, "") }
            var timeline = Timeline()
            timeline.run(world: world, external: [
                (.zero, .target(studio)),
                (sleep, .target(studioAsleep)),
                // Presence says offline under a live link: the machine keeps
                // it and probes; the sleeping Mac does not answer.
                (sleep + LinkController.presenceProbeTimeout, .probeFailed(generation: 1, reason: timeoutReason)),
                (wake, .target(studio)),
            ], until: wake + .seconds(30))
            let reconnected = timeline.connected(after: wake).map { $0 - wake }
            report("host_mac_asleep_then_wakes", variant, [
                "asleep_s": asleep.seconds, "reconnect_ms": (reconnected?.seconds ?? -1) * 1000, "dials": timeline.dials,
            ])
            #expect(timeline.dials == 2, "\(variant): dialed a sleeping Mac (\(timeline.dials) dials)")
            #expect(timeline.statusLines(from: sleep + .seconds(2), to: wake) == ["Offline"])
            #expect(reconnected != nil && reconnected! <= dialTime + .milliseconds(1))
            results.append(reconnected ?? .seconds(3600))
        }
        #expect(withinGodBound(small: results[0], god: results[1]))
    }

    /// The Mac's network sleeps before its presence does (the signaling
    /// socket lingers): probes fail, dials time out and back off. On wake its
    /// socket reconnects, a presence frame arrives (`macSignaled`), and the
    /// phone dials at once instead of waiting out a 30 s backoff step.
    @Test func cellHostMacAsleepPresenceLingers() {
        var results: [Duration] = []
        for (variant, asleep) in [("small-1min", Duration.seconds(60)), ("god-8h", Duration.seconds(8 * 3600))] {
            let sleep: Duration = .seconds(5)
            let wake = sleep + asleep
            let world = World { t in t >= sleep && t < wake ? (false, .seconds(25), timeoutReason) : (true, dialTime, "") }
            var timeline = Timeline()
            timeline.run(world: world, external: [
                (.zero, .target(studio)),
                (sleep, .probeFailed(generation: 1, reason: timeoutReason)),
                (wake, .macSignaled),
            ], until: wake + .seconds(60))
            let reconnected = timeline.connected(after: wake).map { $0 - wake }
            report("host_mac_asleep_presence_lingers", variant, [
                "asleep_s": asleep.seconds, "reconnect_ms": (reconnected?.seconds ?? -1) * 1000, "dials": timeline.dials,
            ])
            // A dial in flight at wake times out against the old offer (25 s)
            // unless presence restarts it; it must not take that long.
            #expect(reconnected != nil && reconnected! <= .seconds(2), "\(variant): \(String(describing: reconnected))")
            results.append(reconnected ?? .seconds(3600))
        }
        #expect(withinGodBound(small: results[0], god: results[1]), "god \(results[1]) vs small \(results[0])")
    }

    /// The Mac app (cmux-mobile-host) restarts under a live link: the link
    /// drops, the first redial's offer reaches a host that is down, the host
    /// is back on signaling 1.6 s later and its presence frame restarts the
    /// dial. Reconnected within 2 s of the host being back.
    @Test func cellHostMacAppRestart() {
        let drop: Duration = .seconds(5)
        let back = drop + .milliseconds(1600)
        let world = World { t in t < drop || t >= back ? (true, dialTime, "") : (false, .seconds(25), timeoutReason) }
        var timeline = Timeline()
        timeline.run(world: world, external: [
            (.zero, .target(studio)),
            (drop, .linkDropped(generation: 1, reason: "peer closed the link")),
            (back, .macSignaled),
        ], until: back + .seconds(60))
        let reconnected = timeline.connected(after: back).map { $0 - back }
        report("host_mac_app_restart", "small", ["reconnect_ms": (reconnected?.seconds ?? -1) * 1000])
        #expect(reconnected != nil && reconnected! <= .seconds(2))
        #expect(!timeline.statusLines(from: drop, to: back).contains("Offline"))
    }

    // MARK: Pairing

    /// An expired access token: the dial is refused with 401, the silent
    /// retry mints a fresh token and connects. The person sees nothing.
    @MainActor @Test func cellPairingExpiredToken() async throws {
        let dialer = ScriptedDialer(outcomes: [.fail(LinkError(code: "unauthorized", message: "signaling refused: 401")), .connect])
        let controller = ScriptedDialer.controller(dialer)
        defer { controller.send(.target(nil)) }
        try await eventually { controller.phase.isConnected }
        report("pairing_expired_token", "small", ["dials": dialer.dials, "force_refresh": dialer.forcedRefresh])
        #expect(dialer.dials == 2)
        #expect(dialer.forcedRefresh == [false, true], "the retry after a 401 must mint a fresh token")
    }

    /// The account's session was revoked (signed out elsewhere, refresh token
    /// gone): minting a token fails with 401. The person must be asked to
    /// sign in again, not shown "Reconnecting…" forever.
    @MainActor @Test func cellPairingRevokedToken() async throws {
        let failure = LiveAPI.Failure(status: 401, code: "unauthorized", message: "refresh token revoked")
        let dialer = ScriptedDialer(outcomes: [.connect])
        let controller = ScriptedDialer.controller(dialer) { _ in throw failure }
        defer { controller.send(.target(nil)) }
        try await eventually { controller.phase == .signedOut }
        let shown = controller.phase.statusLine(macName: "Studio")
        report("pairing_revoked_token", "small", ["status": shown ?? "", "dials": dialer.dials])
        #expect(shown == "Signed out", "a revoked session says \(shown ?? "nothing")")
        // One mint, then one forced refresh; both refused, and no dial was made.
        #expect(dialer.forcedRefresh == [false, true])
        #expect(dialer.dials == 0)
    }

    /// The token mints, but the cmux service refuses it at the dial (the
    /// signaling upgrade answers 401, which the Rust link reports as
    /// `unauthorized`), the refreshed one too: signed out, and no event
    /// dials again.
    @MainActor @Test func cellPairingRevokedTokenRefusedAtDial() async throws {
        let refused = LinkError(code: LinkError.unauthorized, message: "signaling connect failed: 401 Unauthorized")
        let dialer = ScriptedDialer(outcomes: [.fail(refused), .fail(refused)])
        let controller = ScriptedDialer.controller(dialer)
        defer { controller.send(.target(nil)) }
        try await eventually { controller.phase == .signedOut }
        #expect(dialer.forcedRefresh == [false, true], "the second dial must mint a fresh token")
        for event: LinkMachine.Event in [.foreground, .resume, .macSignaled, .networkChanged, .retryDue(generation: controller.dialGeneration)] {
            controller.send(event)
        }
        try await Task.sleep(for: .milliseconds(50))
        report("pairing_revoked_token_at_dial", "small", ["dials": dialer.dials, "status": controller.phase.statusLine(macName: "Studio") ?? ""])
        #expect(dialer.dials == 2, "a signed-out session dialed \(dialer.dials) times")
        #expect(controller.phase == .signedOut)
    }

    /// The link of a signed-out Mac is closed as idle (`applyLinks` sends
    /// `.target(nil)`) and opened again when the Mac is shown: still signed
    /// out, and no dial until the person signs in again.
    @MainActor @Test func cellPairingRevokedTokenSurvivesIdleClose() async throws {
        let refused = LinkError(code: LinkError.unauthorized, message: "signaling connect failed: 401 Unauthorized")
        let dialer = ScriptedDialer(outcomes: [.fail(refused), .fail(refused)])
        let controller = ScriptedDialer.controller(dialer)
        defer { controller.send(.target(nil)) }
        try await eventually { controller.phase == .signedOut }
        controller.send(.target(nil))
        controller.send(.target(.init(macID: "m1", name: "Studio", isOnline: true)))
        try await Task.sleep(for: .milliseconds(50))
        report("pairing_revoked_token_idle_close", "small", ["dials": dialer.dials])
        #expect(dialer.dials == 2, "an idle close and reopen redialed a signed-out session")
        #expect(controller.phase == .signedOut)
    }
}

// MARK: Scripted dialer

private final class ScriptedLink: MacLink, @unchecked Sendable {
    let transport: CmuxMobileTransport.TransportKind = .wireGuard
    let connectedPath: LinkPathKind? = .direct
    let states: AsyncStream<LinkState>
    private let continuation: AsyncStream<LinkState>.Continuation
    init() {
        (states, continuation) = AsyncStream.makeStream()
        continuation.yield(.connected(.wireGuard, .direct, rttMillis: 5))
    }
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: service)
    }
    func ping() async throws -> UInt32 { 5 }
    func probe(timeout: Duration) async throws -> UInt32? { 5 }
    func close() async { continuation.finish() }
}

private final class ScriptedDialer: MacLinkDialer, @unchecked Sendable {
    enum Outcome { case connect, fail(any Error) }
    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var count = 0
    private var refreshes: [Bool] = []
    var dials: Int { lock.withLock { count } }
    var forcedRefresh: [Bool] { lock.withLock { refreshes } }

    init(outcomes: [Outcome]) { self.outcomes = outcomes }

    func noteToken(forceRefresh: Bool) { lock.withLock { refreshes.append(forceRefresh) } }

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let outcome = lock.withLock { () -> Outcome in
            count += 1
            return outcomes.isEmpty ? .connect : outcomes.removeFirst()
        }
        switch outcome {
        case .connect: return ScriptedLink()
        case .fail(let error): throw error
        }
    }

    @MainActor
    static func controller(
        _ dialer: ScriptedDialer,
        token: (@Sendable (Bool) async throws -> String)? = nil
    ) -> LinkController {
        let controller = LinkController(transport: .wireGuard, dialer: dialer, clock: LinkTestClock()) { force in
            dialer.noteToken(forceRefresh: force)
            if let token { return try await token(force) }
            return "token"
        }
        controller.endpoint = {
            LinkEndpoint(baseURL: URL(string: "https://example.invalid")!, teamID: "t", deviceID: "d", macDeviceID: $0)
        }
        controller.send(.target(.init(macID: "m1", name: "Studio", isOnline: true)))
        return controller
    }
}

@MainActor
private func eventually(_ condition: () -> Bool, within: Duration = .seconds(20),
                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + within
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition(), "timed out", sourceLocation: sourceLocation)
}
