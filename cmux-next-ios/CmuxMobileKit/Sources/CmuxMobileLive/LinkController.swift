import class CmuxMobileModel.ConnectTimeline
import enum CmuxMobileModel.DeveloperOptions
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
    @ObservationIgnored private var dialTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// How often a live link is pinged, and how long a ping may take.
    nonisolated static let heartbeat: Duration = .seconds(15)
    nonisolated static let probeTimeout: Duration = .seconds(8)
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
    @ObservationIgnored public var onLink: (@MainActor ((any MacLink)?) -> Void)?
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
        accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String
    ) {
        machine = LinkMachine(transport: transport, relayOnly: relayOnly, blockUDP: blockUDP)
        self.dialer = dialer
        self.clock = clock
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
                                            forceRefresh: Bool,
                                            accessToken: @Sendable (Bool) async throws -> String) async throws -> any MacLink {
        let token = try await accessToken(forceRefresh)
        ConnectTimeline.shared.mark("token_ready")
        let link = try await dialer.dial(endpoint, transport: transport, accessToken: token)
        if let timed = link as? any TimedMacLink {
            let steps = timed.timings.map { "\($0.0)=\(Int($0.1.rounded()))" }.joined(separator: " ")
            ConnectTimeline.shared.mark("link_connected", detail: steps)
        } else {
            ConnectTimeline.shared.mark("link_connected")
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
            guard let self, !Task.isCancelled else { return }
            if case .waiting = self.phase { self.send(.foreground) }
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
        let effects = machine.handle(event)
        quickProbe = event == .foreground && effects.contains { if case .probe = $0 { true } else { false } }
        if phase != machine.phase {
            log.info("link \(String(describing: self.machine.phase), privacy: .public)")
            phase = machine.phase
        }
        if media != machine.media {
            log.info("link media \(String(describing: self.machine.media), privacy: .public)")
            ConnectTimeline.shared.mark("media", detail: String(describing: machine.media))
            media = machine.media
        }
        if case .waiting(_, _, let reason, _) = machine.phase { lastFailure = reason }
        if machine.phase.isConnected { lastFailure = nil }
        for effect in effects { run(effect) }
    }

    private func run(_ effect: LinkMachine.Effect) {
        switch effect {
        case .close:
            dialTask?.cancel()
            watchTask?.cancel()
            heartbeatTask?.cancel()
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
            // The token, the dial and the coordinator's first channels start
            // now, off the main actor; this task (main actor) only waits for
            // the link and adopts it.
            let prepare = prepare
            let macDeviceID = endpoint.macDeviceID
            let work = Task.detached { () async throws -> (link: any MacLink, prepared: (any Sendable)?) in
                let link = try await Self.connect(dialer: dialer, endpoint: endpoint, transport: transport,
                                                  forceRefresh: forceRefresh, accessToken: accessToken)
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
                    if "\(error)".contains("401") { self?.refreshTokenNextDial = true }
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
            let timeout = quickProbe ? Self.foregroundProbeTimeout : Self.probeTimeout
            quickProbe = false
            probe(generation: generation, timeout: timeout)
        case .quickProbe(let generation):
            probe(generation: generation, timeout: Self.presenceProbeTimeout)
        }
    }

    private func probe(generation: Int, timeout: Duration) {
        guard let link else { return }
        let clock = clock
        Task { [weak self] in
            // The link's probe: the pong, or any frame from the Mac within the
            // timeout (a pong behind a busy queue on a slow relay is not a dead
            // link; closing such links was the "peer closed the link" 22 to
            // 24 s after link up of link-reliability-20261023.md). The race
            // stays as a bound: the FFI call ignores cancellation.
            let result = await Self.race(timeout: timeout + Self.probeGrace, clock: clock) {
                try await link.probe(timeout: timeout)
            }
            guard let self else { return }
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
        var initialPath = LinkPathKind.direct
        watchTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                switch state {
                case .connected(_, let path, let rtt):
                    if case .connecting = self.machine.phase {
                        initialPath = path
                        self.send(.dialSucceeded(generation: generation, path: path))
                        self.onLink?(link)
                    }
                    self.send(.linkUpdated(generation: generation, path: path, rttMillis: rtt))
                case .media(let state):
                    self.send(.mediaUpdated(generation: generation, state))
                case .disconnected(let reason):
                    log.info("link dropped: \(reason, privacy: .public)")
                    self.send(.linkDropped(generation: generation, reason: reason))
                case .idle, .connecting:
                    break
                }
            }
            _ = initialPath
        }
        // Measure RTT once up front so the status line has a number quickly,
        // then keep probing so a silent Mac is noticed.
        send(.foreground)
        // A link that knows it is up is connected now: the state stream's first
        // element would only say so a main-actor turn later.
        if let path = link.connectedPath, case .connecting = machine.phase {
            send(.dialSucceeded(generation: generation, path: path))
            onLink?(link)
        }
        heartbeatTask?.cancel()
        let clock = clock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.heartbeat) } catch { return }
                guard let self, generation == self.machine.generation else { return }
                self.run(.probe(generation: generation))
            }
        }
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

    /// A short, display-safe reason for a dial or link error.
    nonisolated static func reason(_ error: any Error) -> String {
        if let error = error as? LinkError {
            switch error.code {
            case "timeout": return "the Mac didn't answer in time"
            case "not_admitted": return "the Mac refused this phone"
            case "offline": return "the Mac is offline"
            default:
                let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? error.code : String(message.prefix(80))
            }
        }
        if error is LiveAPI.Failure { return "the cmux service refused the request" }
        return String(error.localizedDescription.prefix(80))
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
