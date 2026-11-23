import CmuxConnectivityTelemetry
import class CmuxMobileModel.ConnectTimeline
import enum CmuxMobileModel.DeveloperOptions
import enum CmuxMobileModel.UserFacingError
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "link")

/// Runs `LinkMachine` against a real dialer: dials, watches the link's state
/// stream, schedules retries on an injected clock, and hands the live link
/// to `onLink` (nil when it goes away).
@MainActor
@Observable
public final class LinkController {
    public private(set) var phase: LinkMachine.Phase = .idle
    public private(set) var link: (any MacLink)?
    /// The last failure, kept while reconnecting (Settings shows it).
    public private(set) var lastFailure: String?
    /// The WebRTC media session beside the current WireGuard link.
    public private(set) var media: VideoMediaState = .off

    @ObservationIgnored private var machine: LinkMachine
    /// Bumped by every dial, close and wait the machine starts.
    public var dialGeneration: Int { machine.generation }
    @ObservationIgnored private let dialer: any MacLinkDialer
    /// Resolves a Mac id to a dial endpoint (nil until the phone is registered).
    @ObservationIgnored public var endpoint: @MainActor (String) -> LinkEndpoint? = { _ in nil }
    @ObservationIgnored private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    /// The last dial was refused with 401: the next dial mints a fresh token.
    @ObservationIgnored private var refreshTokenNextDial = false
    @ObservationIgnored private let clock: any Clock<Duration>
    /// Settings → Transport → Align Keepalives: the heartbeat's beats.
    @ObservationIgnored private let beat: KeepaliveBeat
    /// Every dial, phase, probe, drop and roam, for connectivity telemetry (team: verbose).
    @ObservationIgnored private let events: LinkConnectivityEvents
    @ObservationIgnored private var dialTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// Foreground silence is detected within 5 s: 2.5 s of quiet until a
    /// probe, 2 s for any inbound frame, and 0.5 s grace for the FFI
    /// boundary. A link that received a frame within the beat is not probed.
    nonisolated static let heartbeat: Duration = .milliseconds(2500)
    nonisolated static let probeTimeout: Duration = .seconds(2)
    nonisolated static let backgroundHeartbeat: Duration = .seconds(15)
    nonisolated static let backgroundProbeTimeout: Duration = .seconds(8)
    /// After a foreground a link that does not answer within this is redialed:
    /// a phone back from the background must not wait 8 s on a dead link.
    nonisolated static let foregroundProbeTimeout: Duration = .milliseconds(2000)
    /// A link that does not answer within this after presence changed under
    /// it (the Mac's signaling socket went or came back) is redialed: its
    /// host may have restarted (termfix-r13 D2b: the dead link was kept until
    /// the heartbeat, 26.7 s). A live link answers in milliseconds.
    nonisolated static let presenceProbeTimeout: Duration = .milliseconds(1500)
    /// Beyond a probe's own timeout, how long the bound around it waits.
    nonisolated static let probeGrace: Duration = .milliseconds(500)
    @ObservationIgnored private var quickProbe = false
    /// The link kept beside a redial after its probe failed
    /// (``LinkMachine/standby``), its state watch and its probe loop.
    @ObservationIgnored private(set) var standbyLink: (any MacLink)?
    @ObservationIgnored private var standbyWatchTask: Task<Void, Never>?
    @ObservationIgnored private var standbyTask: Task<Void, Never>?
    /// The standby link is probed one probe at a time, each bounded by
    /// ``standbyProbeTimeout``, with this gap between them: a path back from
    /// a blackout carries traffic again within both plus one round trip
    /// (1.25 s). Only while there is a standby (at most ``standbyLimit``):
    /// about 36 pings, a few KB, per blackout; nothing while idle.
    nonisolated static let standbyProbeEvery: Duration = .milliseconds(250)
    nonisolated static let standbyProbeTimeout: Duration = .seconds(1)
    /// How long a silent standby link is kept. Past the 30 s blackout of
    /// an elevator; the Rust link closes on its own keepalive before that
    /// when the Mac is gone.
    nonisolated static let standbyLimit: Duration = .seconds(45)
    /// The probes that fill ``standbyLimit``, one per probe and gap (36).
    nonisolated static let standbyProbes = Int(standbyLimit / (standbyProbeTimeout + standbyProbeEvery))
    /// What the timers did, for tests that move a test clock: how many heartbeat tasks were
    /// started and how many have begun running, how many times the heartbeat went to sleep and for
    /// how long the last time, and how many probes started and the last one's timeout. Counters
    /// only; nothing reads them to decide.
    @ObservationIgnored private(set) var heartbeatStarts = 0
    @ObservationIgnored private(set) var heartbeatsBegun = 0
    @ObservationIgnored private(set) var heartbeatSleeps = 0
    @ObservationIgnored private(set) var lastHeartbeatWait: Duration = .zero
    @ObservationIgnored private(set) var probeStarts = 0
    @ObservationIgnored private(set) var lastProbeTimeout: Duration = .zero
    /// A probe is out and its result not yet handled.
    var isProbing: Bool { probeTask != nil }
    @ObservationIgnored public var onLink: (@MainActor ((any MacLink)?) -> Void)?
    /// Every phase change and every drop of a live link, for the connectivity incident detector.
    @ObservationIgnored public var onSignal: (@MainActor (LinkSignal) -> Void)?

    /// What ``onSignal`` reports.
    public enum LinkSignal: Equatable, Sendable {
        case phase(LinkMachine.Phase)
        /// A live link died under the phone (its stream ended or a probe went unanswered); deliberate
        /// redials (a resume, a transport switch, a retarget) are not drops.
        case dropped(reason: String)
        /// A dial failed (not one a newer dial cancelled); the first is retried at once, without a
        /// waiting phase, so this is where its reason is seen.
        case dialFailed(reason: String)
    }
    /// Runs right after a dial, in the same detached step (no main actor):
    /// the coordinator opens the channels it needs first (`auth`, `daemon`)
    /// and sends its setup batch, so the live list needs no main-actor turn
    /// per channel. Its result is held for the link (`takePrepared(for:)`).
    @ObservationIgnored public var prepare: (@Sendable (any MacLink, _ macID: String) async -> (any Sendable)?)?
    /// What `prepare` returned for the adopted link.
    @ObservationIgnored private var prepared: (link: ObjectIdentifier, value: any Sendable)?

    /// What `prepare` made for `link`, once (nil for another link, or taken).
    public func takePrepared(for link: any MacLink) -> (any Sendable)? {
        guard let prepared, prepared.link == ObjectIdentifier(link) else { return nil }
        self.prepared = nil
        return prepared.value
    }

    public init(
        transport: TransportKind,
        relayOnly: Bool = false,
        blockUDP: Bool = false,
        dialer: any MacLinkDialer,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: ConnectivityTelemetry = .shared,
        beat: KeepaliveBeat = .live,
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String
    ) {
        machine = LinkMachine(transport: transport, relayOnly: relayOnly, blockUDP: blockUDP)
        self.dialer = dialer
        self.clock = clock
        self.beat = beat
        self.events = LinkConnectivityEvents(telemetry: telemetry)
        self.accessToken = accessToken
    }

    public var target: LinkMachine.Target? { machine.target }

    /// Warms the next dial in `teamID` (signaling socket, ICE servers); logs the steps.
    public func prewarm(baseURL: URL, teamID: String, deviceID: String) {
        let dialer = dialer
        let accessToken = accessToken
        // Detached: a task that starts on the main actor waits for it first.
        Task.detached { await Self.prewarm(dialer: dialer, accessToken: accessToken, baseURL: baseURL, teamID: teamID, deviceID: deviceID) }
    }

    /// Off the main actor: at launch it is busy drawing the first frames.
    private nonisolated static func prewarm(dialer: any MacLinkDialer, accessToken: @Sendable (Bool) async throws -> String,
                                            baseURL: URL, teamID: String, deviceID: String) async {
        guard let token = try? await accessToken(false) else { return }
        let steps = await dialer.prewarm(baseURL: baseURL, teamID: teamID, deviceID: deviceID, accessToken: token)
        guard !steps.isEmpty else { return }
        ConnectTimeline.shared.mark("prewarmed", detail: steps.map { "\($0.0)=\(Int($0.1.rounded()))" }.joined(separator: " "))
    }

    /// The token and the dial, off the main actor (verify/perf-latency.md: at
    /// launch the main actor is busy drawing the first frames, and the dial
    /// waited for it twice, about 0.45 s). Only adopting the link needs it.
    private nonisolated static func connect(dialer: any MacLinkDialer, endpoint: LinkEndpoint, transport: TransportKind,
                                            forceRefresh: Bool, events: LinkConnectivityEvents,
                                            accessToken: @Sendable (Bool) async throws -> String) async throws -> any MacLink {
        let token = try await accessToken(forceRefresh)
        ConnectTimeline.shared.mark("token_ready")
        let link = try await dialer.dial(endpoint, transport: transport, accessToken: token)
        if let timed = link as? any TimedMacLink {
            let steps = timed.timings.map { "\($0.0)=\(Int($0.1.rounded()))" }.joined(separator: " ")
            ConnectTimeline.shared.mark("link_connected", detail: steps)
            events.connected(timed.timings)
        } else {
            ConnectTimeline.shared.mark("link_connected")
            events.connected([])
        }
        return link
    }

    /// Path updates come in bursts (one interface goes, another comes);
    /// the roam waits this long for the burst to end.
    nonisolated static let networkSettle: Duration = .milliseconds(150)
    @ObservationIgnored private var networkTask: Task<Void, Never>?

    /// The phone's network changed or came back: the live link moves onto it
    /// without a redial (WireGuard roams in place), and a link that already
    /// failed redials now instead of at its backoff.
    public func networkChanged(baseURL: URL, teamID: String, deviceID: String) {
        networkTask?.cancel()
        let dialer = dialer
        let accessToken = accessToken
        let clock = clock
        let events = events
        networkTask = Task { [weak self] in
            do { try await clock.sleep(for: Self.networkSettle) } catch { return }
            ConnectTimeline.shared.mark("network_changed")
            // Detached: the roam must not wait for the main actor.
            let steps = await Task.detached { () -> [(String, Double)] in
                guard let token = try? await accessToken(false) else { return [] }
                return await dialer.networkChanged(baseURL: baseURL, teamID: teamID, deviceID: deviceID, accessToken: token)
            }.value
            log.info("network changed: \(steps.map { "\($0.0)=\(Int($0.1.rounded()))" }.joined(separator: " "), privacy: .public)")
            ConnectTimeline.shared.mark("network_roamed", detail: steps.map { "\($0.0)=\(Int($0.1.rounded()))" }.joined(separator: " "))
            events.roamed(steps)
            guard let self, !Task.isCancelled else { return }
            self.send(.networkChanged)
        }
    }

    /// Sign-out: forget warm sockets and cached servers.
    public func resetWarmState() async {
        await dialer.resetWarmState()
    }
    public var transport: TransportKind { machine.transport }
    public var relayOnly: Bool { machine.relayOnly }
    public var blockUDP: Bool { machine.blockUDP }

    public func send(_ event: LinkMachine.Event) {
        let wasBackgrounded = machine.isBackgrounded
        let wasConnected = machine.phase.isConnected
        let effects = machine.handle(event)
        switch event {
        case .linkDropped(_, let reason), .probeFailed(_, let reason):
            if wasConnected, !machine.phase.isConnected { onSignal?(.dropped(reason: reason)) }
        default:
            break
        }
        quickProbe = (event == .foreground || event == .resume || { if case .resumed = event { true } else { false } }()) && effects.contains { if case .probe = $0 { true } else { false } }
        if phase != machine.phase {
            log.info("link \(String(describing: self.machine.phase), privacy: .public)")
            phase = machine.phase
            events.phaseChanged(phase, macID: machine.target?.macID)
            onSignal?(.phase(phase))
        }
        if media != machine.media {
            log.info("link media \(String(describing: self.machine.media), privacy: .public)")
            ConnectTimeline.shared.mark("media", detail: String(describing: machine.media))
            media = machine.media
            events.media(media)
        }
        if case .waiting(_, _, let reason, _) = machine.phase { lastFailure = reason }
        if machine.phase.isConnected { lastFailure = nil }
        // Before the effects: a background probe still out is cancelled first, so a probe an
        // effect starts now (a short resume's quick probe) is the one that runs.
        if wasBackgrounded != machine.isBackgrounded, phase.isConnected {
            probeTask?.cancel()
            probeTask = nil
            startHeartbeat(generation: machine.generation)
        }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: LinkMachine.Effect) {
        switch effect {
        case .close:
            closeStandby()
            dialTask?.cancel()
            watchTask?.cancel()
            heartbeatTask?.cancel()
            probeTask?.cancel()
            probeTask = nil
            retryTask?.cancel()
            prepared = nil
            if let link {
                self.link = nil
                onLink?(nil)
                Task { await link.close() }
            }
        case .dial(let generation, let macID, let transport):
            dialTask?.cancel()
            retryTask?.cancel()
            guard var endpoint = endpoint(macID) else {
                events.dialSkipped(macID: macID)
                send(.dialFailed(generation: generation, reason: "not registered yet"))
                return
            }
            endpoint.relayOnly = machine.relayOnly
            endpoint.blockUDP = machine.blockUDP
            endpoint.browserVideoOnChannel = DeveloperOptions.browserVideoOnChannel
            log.info("dial \(transport.rawValue, privacy: .public) relayOnly=\(endpoint.relayOnly, privacy: .public) blockUDP=\(endpoint.blockUDP, privacy: .public)")
            let dialer = dialer
            let accessToken = accessToken
            let forceRefresh = refreshTokenNextDial
            refreshTokenNextDial = false
            ConnectTimeline.shared.mark("dial_start", detail: transport.rawValue)
            events.dialStarted(transport: transport, endpoint: endpoint)
            let events = events
            // The token, the dial and the coordinator's first channels start
            // now, off the main actor; this task (main actor) only waits for
            // the link and adopts it.
            let prepare = prepare
            let macDeviceID = endpoint.macDeviceID
            let work = Task.detached { () async throws -> (link: any MacLink, prepared: (any Sendable)?) in
                let link = try await Self.connect(dialer: dialer, endpoint: endpoint, transport: transport,
                                                  forceRefresh: forceRefresh, events: events, accessToken: accessToken)
                guard let prepare, !Task.isCancelled else { return (link, nil) }
                return (link, await prepare(link, macDeviceID))
            }
            dialTask = Task { [weak self] in
                do {
                    let (link, prepared) = try await withTaskCancellationHandler {
                        try await work.value
                    } onCancel: {
                        work.cancel()
                    }
                    guard let self, !Task.isCancelled, generation == self.machine.generation else {
                        await link.close()
                        return
                    }
                    self.prepared = prepared.map { (ObjectIdentifier(link), $0) }
                    self.adopt(link, generation: generation)
                } catch {
                    log.error("dial failed: \(String(describing: error), privacy: .public)")
                    // A dial cancelled by a newer one (re-target, foreground) is not a failure.
                    if !Task.isCancelled, !(error is CancellationError), generation == self?.machine.generation {
                        events.dialFailed(error, transport: transport)
                        self?.onSignal?(.dialFailed(reason: Self.reason(error)))
                    }
                    if Self.sessionRevoked(error, afterRefresh: forceRefresh) {
                        // A fresh token was refused too: the account's session is
                        // gone, and no redial can fix that (matrix cell
                        // pairing_revoked_token).
                        self?.send(.signedOut(generation: generation))
                        return
                    }
                    if Self.authRefused(error) { self?.refreshTokenNextDial = true }
                    self?.send(.dialFailed(generation: generation, reason: Self.reason(error)))
                }
            }
        case .scheduleRetry(let generation, let delay):
            retryTask?.cancel()
            let clock = clock
            retryTask = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                self?.send(.retryDue(generation: generation))
            }
        case .probe(let generation):
            let timeout = quickProbe ? Self.foregroundProbeTimeout
                : (machine.isBackgrounded ? Self.backgroundProbeTimeout : Self.probeTimeout)
            quickProbe = false
            probe(generation: generation, timeout: timeout)
        case .quickProbe(let generation):
            probe(generation: generation, timeout: Self.presenceProbeTimeout)
        case .keepStandby:
            keepStandby()
        case .promoteStandby(let generation):
            promoteStandby(generation: generation)
        case .closeStandby:
            closeStandby()
        }
    }

    /// The live link becomes the standby: its heartbeat stops, its channels
    /// and the coordinator's hold on it stay (no `onLink(nil)`), and a loop
    /// probes it until it answers, closes or ``standbyLimit`` passes.
    private func keepStandby() {
        closeStandby()
        guard let link, let generation = machine.standby else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        probeTask?.cancel()
        probeTask = nil
        self.link = nil
        standbyLink = link
        // The watch keeps running (cancelling it would end the link's state
        // stream); it reports the standby's close as `standbyLost`.
        standbyWatchTask = watchTask
        watchTask = nil
        ConnectTimeline.shared.mark("link_standby")
        let clock = clock
        standbyTask = Task { [weak self] in
            for _ in 0..<Self.standbyProbes where !Task.isCancelled {
                let result = await Self.race(timeout: Self.standbyProbeTimeout + Self.probeGrace, clock: clock) {
                    try await link.probe(timeout: Self.standbyProbeTimeout)
                }
                guard let self, !Task.isCancelled, self.machine.standby == generation else { return }
                if case .success(let rtt) = result {
                    ConnectTimeline.shared.mark("link_standby_alive", detail: rtt.map { "\($0) ms" } ?? "traffic")
                    self.send(.standbyAlive(generation: generation, path: link.connectedPath ?? .noPath, rttMillis: rtt))
                    return
                }
                do { try await clock.sleep(for: Self.standbyProbeEvery) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.send(.standbyLost(generation: generation))
        }
    }

    /// The standby answered first: it is the link again under `generation`,
    /// with its channels as they were. The redial is dropped.
    private func promoteStandby(generation: Int) {
        guard let standby = standbyLink else { return }
        dialTask?.cancel()
        dialTask = nil
        retryTask?.cancel()
        standbyTask?.cancel()
        standbyTask = nil
        standbyLink = nil
        watchTask?.cancel()
        watchTask = standbyWatchTask
        standbyWatchTask = nil
        prepared = nil
        // A redial adopted but not yet connected (`onLink` not called for it):
        // never handed to the coordinator, so it only closes.
        if let fresh = link, ObjectIdentifier(fresh) != ObjectIdentifier(standby) {
            Task { await fresh.close() }
        }
        link = standby
        ConnectTimeline.shared.mark("link_standby_promoted")
        startHeartbeat(generation: generation)
    }

    private func closeStandby() {
        standbyTask?.cancel()
        standbyTask = nil
        standbyWatchTask?.cancel()
        standbyWatchTask = nil
        if let standby = standbyLink {
            standbyLink = nil
            Task { await standby.close() }
        }
    }

    /// A channel on this link died or went silent while the link looked up
    /// (a terminal's liveness check): prove the link now with the quick
    /// probe, so a link that is really dead is redialed at once instead of
    /// after its heartbeat (Leo, 2026-11-21: "intermittent 30s lag/disconnects").
    /// A no-op while a probe runs or the link is not connected.
    public func suspect() {
        guard phase.isConnected else { return }
        run(.quickProbe(generation: machine.generation))
    }

    private func probe(generation: Int, timeout: Duration) {
        guard let link, phase.isConnected, generation == machine.generation, probeTask == nil else { return }
        let clock = clock
        probeStarts += 1
        lastProbeTimeout = timeout
        probeTask = Task { [weak self] in
            // The link's probe: the pong, or any frame from the Mac within the
            // timeout (a pong behind a busy queue on a slow relay is not a dead
            // link; closing such links was the "peer closed the link" 22 to
            // 24 s after link up of link-reliability-20261023.md). The race
            // stays as a bound: the FFI call ignores cancellation.
            let result = await Self.race(timeout: timeout + Self.probeGrace, clock: clock) {
                try await link.probe(timeout: timeout)
            }
            guard let self, !Task.isCancelled, generation == self.machine.generation else { return }
            self.probeTask = nil
            self.events.probed(result)
            switch result {
            case .success(let rtt):
                ConnectTimeline.shared.mark("link_alive", detail: rtt.map { "\($0) ms" } ?? "traffic")
                guard case .connected(_, let path, _) = self.phase else { return }
                // Alive without a pong: no new round trip to show (nil keeps the last one).
                self.send(.linkUpdated(generation: generation, path: path, rttMillis: rtt))
            case .failure(let error):
                self.send(.probeFailed(generation: generation, reason: Self.reason(error)))
            }
        }
    }

    private func adopt(_ link: any MacLink, generation: Int) {
        ConnectTimeline.shared.mark("link_adopted")
        self.link = link
        watchTask?.cancel()
        let states = link.states
        let id = ObjectIdentifier(link)
        watchTask = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                // Kept beside a redial: only its close matters.
                if let standby = self.standbyLink, ObjectIdentifier(standby) == id {
                    if case .disconnected = state, let kept = self.machine.standby {
                        self.send(.standbyLost(generation: kept))
                    }
                    continue
                }
                // The live link, under whatever generation it has now (a
                // standby promoted back takes a new one).
                guard let live = self.link, ObjectIdentifier(live) == id else { return }
                let generation = self.machine.generation
                switch state {
                case .connected(_, let path, let rtt):
                    if case .connecting = self.machine.phase {
                        self.connected(link, generation: generation, path: path)
                    }
                    self.send(.linkUpdated(generation: generation, path: path, rttMillis: rtt))
                case .media(let state):
                    self.send(.mediaUpdated(generation: generation, state))
                case .disconnected(let reason):
                    log.info("link dropped: \(reason, privacy: .public)")
                    self.events.dropped(reason: reason)
                    self.send(.linkDropped(generation: generation, reason: reason))
                case .suspect(let silentMillis):
                    // Rust heard nothing after a ping: prove the link now (cmux#49296).
                    log.info("link suspect: silent \(silentMillis, privacy: .public) ms")
                    self.suspect()
                case .idle, .connecting:
                    break
                }
            }
        }
        // A link that knows it is up is connected now: the state stream's first
        // element would only say so a main-actor turn later.
        if let path = link.connectedPath, case .connecting = machine.phase {
            connected(link, generation: generation, path: path)
        }
    }

    /// Both adoption paths start liveness only after the machine is connected.
    private func connected(_ link: any MacLink, generation: Int, path: LinkPathKind) {
        send(.dialSucceeded(generation: generation, path: path))
        onLink?(link)
        guard generation == machine.generation, phase.isConnected else { return }
        probe(generation: generation, timeout: machine.isBackgrounded ? Self.backgroundProbeTimeout : Self.foregroundProbeTimeout)
        startHeartbeat(generation: generation)
    }

    /// Replaced on scene activity changes; cancelled on close, and stops if
    /// the controller disappears or a newer link generation takes over.
    private func startHeartbeat(generation: Int) {
        heartbeatTask?.cancel()
        let clock = clock
        let beat = beat
        // Align Keepalives keeps the 2.5 s foreground beat and moves the
        // background one to the 10 s keepalive beat (never longer than 15 s).
        let interval = machine.isBackgrounded
            ? (beat.isOn ? KeepaliveBeat.period : Self.backgroundHeartbeat)
            : Self.heartbeat
        heartbeatStarts += 1
        heartbeatTask = Task { [weak self] in
            self?.heartbeatsBegun += 1
            var wait = beat.delay(toNextBeatOf: interval) ?? interval
            while !Task.isCancelled {
                self?.heartbeatSleeps += 1
                self?.lastHeartbeatWait = wait
                do { try await clock.sleep(for: wait) } catch { return }
                guard !Task.isCancelled, let self, generation == self.machine.generation, self.phase.isConnected else { return }
                if let toBeat = beat.delay(toNextBeatOf: interval) {
                    wait = self.alignedHeartbeat(generation: generation, interval: interval, toBeat: toBeat)
                    continue
                }
                // A frame from the Mac within the beat proves the link alive as
                // a pong would: probe only a link quiet for a whole beat, and
                // look again one beat after its last frame. Silence is then
                // probed as soon as it lasts a beat, so the 5 s bound holds
                // from the last frame, while a busy link (a streaming turn,
                // terminal output) sends no probes at all.
                if let quiet = self.link?.receivedAgo, quiet < interval {
                    wait = interval - quiet
                    continue
                }
                wait = interval
                self.run(.probe(generation: generation))
            }
        }
    }

    /// How far past a beat a wake still counts as on it (timer lateness).
    nonisolated static let beatTolerance: Duration = .milliseconds(50)

    /// One heartbeat wake with Align Keepalives on; returns the next wait.
    /// The rule above still holds (a link quiet for a whole beat is probed,
    /// so the 5 s bound holds from the last frame, and a link with traffic
    /// is not probed), and an idle link, whose only frames are keepalives,
    /// is probed on the beat, with the link ping and the sockets' pings.
    private func alignedHeartbeat(generation: Int, interval: Duration, toBeat: Duration) -> Duration {
        let quiet = link?.receivedAgo
        let onBeat = toBeat >= interval - Self.beatTolerance
        let idle = link?.trafficAgo.map { $0 >= interval } ?? false
        if quiet.map({ $0 >= interval }) ?? true || (onBeat && idle) {
            run(.probe(generation: generation))
            return toBeat
        }
        // The next beat, or one beat after the last frame, whichever is first.
        return min(toBeat, interval - (quiet ?? .zero))
    }

    /// `operation`'s result, or a timeout failure after `timeout`, whichever
    /// comes first. Not a task group: a group waits for every child before it
    /// returns, and the FFI ping ignores cancellation, so a ping on a link the
    /// Mac had already dropped (the app was suspended) held the probe until
    /// the link's own keepalive gave up 20 s later; input typed meanwhile was
    /// lost.
    nonisolated static func race<T: Sendable>(
        timeout: Duration, clock: any Clock<Duration>, _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        let once = RaceOnce()
        return await withCheckedContinuation { continuation in
            let work = Task {
                let result: Result<T, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await clock.sleep(for: timeout)
                if once.claim() {
                    work.cancel()
                    continuation.resume(returning: .failure(LinkError(code: "timeout", message: "")))
                }
            }
        }
    }

    /// Whether `error` says the account's session was revoked: the cmux
    /// service answered 401 to a token minted fresh for this dial (an expired
    /// token is refused once, then refreshed; only a refused refresh is final).
    nonisolated static func sessionRevoked(_ error: any Error, afterRefresh: Bool) -> Bool {
        afterRefresh && authRefused(error)
    }

    /// Whether the cmux service refused the access token (a 401): minting it
    /// (`LiveAPI.Failure`), or the dial's signaling upgrade, which the Rust
    /// link reports as code `unauthorized`.
    nonisolated static func authRefused(_ error: any Error) -> Bool {
        if let failure = error as? LiveAPI.Failure { return failure.status == 401 }
        if let error = error as? LinkError { return error.code == LinkError.unauthorized }
        return false
    }

    /// A short, display-safe reason for a dial or link error.
    /// The mapping lives with ``LinkError`` (`displayReason`); never a code or a type name.
    nonisolated static func reason(_ error: any Error) -> String {
        if let error = error as? LinkError { return error.displayReason }
        if error is LiveAPI.Failure { return "the cmux service refused the request" }
        return String(UserFacingError.message(error, fallback: "the connection to the Mac failed").prefix(80))
    }
}

/// One winner for ``LinkController/race(timeout:clock:_:)``.
final class RaceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
