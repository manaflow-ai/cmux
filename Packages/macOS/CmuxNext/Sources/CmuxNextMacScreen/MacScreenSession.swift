public import CmuxNextRemoteView
public import CmuxScreenKit
import CmuxNextCompat
import CmuxNextWakeups
public import CoreGraphics
import Foundation
public import Observation
import os

/// One Mac Screen tab's stream to another of the user's Macs on cmux.rd/1
/// (plans/cmux-next/remote-desktop-mac-host.md section 7). The device hub
/// approved the session; its ticket's signaling carries this side's offer
/// (session key, quality wish) and the host's answer and candidates.
/// `cmux rd connect` holds the secure link and bridges it to the remote view
/// transport over a private Unix socket, so decoding, presenting and input
/// are the remote view pane's own. One session per approval: a quality or
/// display change asks the hub for a new one (`restart`).
@MainActor @Observable
public final class MacScreenSession {
    private var rdPhase: Phase = .ended
    public private(set) var phase: Phase {
        get {
            guard let fallback else { return rdPhase }
            switch fallback.session.phase {
            case .connecting: return .connecting
            case .connected: return .connected
            case let .failed(message, needsSignIn): return .failed(message: message, needsSignIn: needsSignIn)
            case .ended: return .ended
            }
        }
        set { rdPhase = newValue }
    }
    private var rdStats = LiveStats()
    public private(set) var stats: LiveStats {
        get {
            guard let value = fallback?.session.stats else { return rdStats }
            return LiveStats(fps: value.fps, kilobytesPerSecond: value.kilobytesPerSecond,
                             latencyMs: value.latencyMs, encoding: value.encoding, targetFps: value.targetFps,
                             framesReceived: value.framesReceived, framesDecoded: value.framesDecoded,
                             framesDropped: value.framesDropped)
        }
        set { rdStats = newValue }
    }
    /// The streamed display's size in pixels (zero until the first frame).
    public private(set) var frameSize: CGSize = .zero
    /// `Direct`, `Tailnet` or `Relayed`, from the link's measured path.
    private var rdStreamPath = "-"
    public private(set) var streamPath: String {
        get { fallback.map { "WebRTC · " + $0.session.streamPath } ?? rdStreamPath }
        set { rdStreamPath = newValue }
    }
    /// A frame stopped arriving while connected (the picture is frozen).
    private var rdIsStalled = false
    public private(set) var isStalled: Bool {
        get { fallback?.session.isStalled ?? rdIsStalled }
        set { rdIsStalled = newValue }
    }
    /// This approach never reconnects on its own: Try Again asks the hub again.
    public var isReconnecting: Bool { false }
    public var preferences: ScreenPreferences
    /// The viewer display's refresh rate; the next session asks for up to it.
    @ObservationIgnored public var displayMaximumFrameRate: Int?
    /// The pane's screen area in pixels, for Auto's stream width (read when a session offers).
    @ObservationIgnored public var paneWidthPixels: Int?
    @ObservationIgnored public var relayOnly = false
    @ObservationIgnored public var reconnectLimit = 0
    /// Relay errors for the failed card (relays are a link carrier, not reported apart).
    public var relayErrors: [ICECandidateError] { [] }
    /// A transport exists while the session runs.
    public var stream: AnyObject? {
        if let fallback { return fallback.session.stream }
        return transport
    }

    /// The display to show in the next session (nil: the host's main display).
    @ObservationIgnored var wantedDisplay: Int?
    /// The pane attaches its decoder to each new transport.
    @ObservationIgnored public var onTransport: ((RemoteRdStreamTransport) -> Void)?
    /// WebRTC uses the pane's existing presenter after Rust permits a carrier fallback.
    @ObservationIgnored public var onVideoTrack: ((VideoTrackBox) -> Void)?
    private var fallback: MacScreenFallback?
    /// Native start boundary; tests observe it without starting the WebRTC engine.
    @ObservationIgnored var startFallback: (MacScreenFallback) -> Void = { $0.start() }
    /// The host's displays (pixel sizes) and the one streamed, from its answer.
    @ObservationIgnored public var onStreamDisplays: (([CGSize], Int) -> Void)?
    /// A quality or display change needs a new hub session (the ticket admits once).
    @ObservationIgnored var restart: () -> Void = {}

    public let title: String
    @ObservationIgnored private let signaling: @MainActor () -> (any ScreenSignaling)?
    @ObservationIgnored private var transport: RemoteRdStreamTransport?
    @ObservationIgnored private var process: (any MacScreenRdWorker)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var socketDirectory: URL?
    @ObservationIgnored private var frameWindow = (start: ContinuousClock.now, frames: 0)
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-session")

    public init(title: String, preferences: ScreenPreferences, signaling: @escaping @MainActor () -> (any ScreenSignaling)?) {
        self.title = title
        self.preferences = preferences
        self.signaling = signaling
    }

    // MARK: Lifecycle

    /// Starts a session on the hub's approved ticket (its signaling, once).
    public func reconnect() { connect() }

    public func connect() { _ = connect(worker: MacScreenRdProcess()) }

    /// The worker owns the terminal decision; injectable without launching a child in lifecycle tests.
    @discardableResult
    func connect(worker process: any MacScreenRdWorker) -> Task<Void, Never>? {
        disconnect()
        guard let signaling = signaling() else {
            phase = .failed(message: L.t("macScreen.rd.noTicket", "The other Mac did not approve a session yet."), needsSignIn: false)
            return nil
        }
        phase = .connecting
        isStalled = false
        frameSize = .zero
        stats = LiveStats()
        do { try process.start(.connect) } catch {
            phase = .failed(message: L.t("macScreen.rd.noBinary", "cmux could not start its screen viewer."), needsSignIn: false)
            return nil
        }
        self.process = process
        signalingOpen = false
        pendingOffer = nil
        let sessionID = (signaling as? TicketSignaling)?.ticket.sessionID ?? UUID().uuidString
        let output = Task<Void, Never> { [weak self] in
            let servers = MacScreenRdServers((try? await signaling.iceServers()) ?? [])
            await self?.followProcess(process, signaling: signaling, sessionID: sessionID, servers: servers)
        }
        tasks.append(output)
        tasks.append(Task { [weak self] in await self?.followSignaling(signaling, process: process) })
        return output
    }

    /// Ends the session here (the hub hears it from the tab's viewer).
    public func disconnect(silently: Bool = false) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        fallback?.close()
        fallback = nil
        transport?.stop()
        transport = nil
        process?.stop()
        process = nil
        if let socketDirectory {
            // The link bridge's private directory goes on a background thread: no disk work on main.
            Task.detached(priority: WorkPriority.bestEffort.taskPriority) { try? FileManager.checked.removeItem(at: socketDirectory) }
        }
        socketDirectory = nil
        if case .connecting = phase { phase = .ended }
        if case .connected = phase { phase = .ended }
    }

    public func close() { disconnect() }

    // MARK: Signaling and the link process

    /// Whether `process` is still this session's (a restart replaced it, or Stop ended it): an
    /// old session's tasks resume after `connect()` started the next one and must not touch it.
    private func isCurrent(_ process: any MacScreenRdWorker) -> Bool {
        self.process === process && !Task.isCancelled
    }

    private func followSignaling(_ signaling: any ScreenSignaling, process: any MacScreenRdWorker) async {
        do {
            for try await signal in signaling.messages() {
                guard isCurrent(process) else { return }
                if let fallback {
                    fallback.forward(signal)
                    continue
                }
                switch signal {
                case .hello:
                    // The session socket is open: an offer waiting for it goes now.
                    signalingOpen = true
                    if let offer = pendingOffer {
                        pendingOffer = nil
                        await sendOffer(offer, signaling: signaling, process: process)
                    }
                case let .answer(text):
                    guard let answer = MacScreenRdDocument(text: text) else {
                        logger.error("cmux rd: an answer that is not a cmux.rd/1 document")
                        continue
                    }
                    logger.info("cmux rd: answer received (\(answer.candidates.count, privacy: .public) candidates)")
                    if !answer.displays.isEmpty { onStreamDisplays?(answer.displays, answer.currentDisplay ?? 0) }
                    answered(answer)
                case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                    process.send(["candidate": candidate.candidate])
                case .bye:
                    end(L.t("macScreen.rd.hostEnded", "The other Mac ended the session."))
                    return
                default:
                    continue
                }
            }
            if isCurrent(process) { fallback?.finish() }
        } catch {
            if isCurrent(process), let fallback {
                fallback.finish(error)
                return
            }
            if isCurrent(process), phase == .connecting {
                fail(L.t("macScreen.rd.signalingFailed", "The session could not reach the other Mac."))
            }
        }
    }

    /// The session socket said hello (it is open, so an offer can go).
    @ObservationIgnored private var signalingOpen = false
    /// This side's offer, made before the socket opened.
    @ObservationIgnored private var pendingOffer: String?

    private func sendOffer(_ text: String, signaling: any ScreenSignaling, process: any MacScreenRdWorker) async {
        logger.info("cmux rd: offer sent")
        do { try await signaling.send(.offer(text)) } catch {
            guard isCurrent(process) else { return }
            fail(L.t("macScreen.rd.signalingFailed", "The session could not reach the other Mac."))
        }
    }

    /// The answer this side waits for, with the session's id and servers.
    @ObservationIgnored private var pendingAnswer: ((MacScreenRdDocument) -> Void)?

    private func answered(_ answer: MacScreenRdDocument) {
        pendingAnswer?(answer)
        pendingAnswer = nil
    }

    private func followProcess(_ process: any MacScreenRdWorker, signaling: any ScreenSignaling, sessionID: String,
                               servers: MacScreenRdServers) async {
        var offered = false
        for await line in process.lines {
            guard isCurrent(process) else { return }
            if line.fallbackToWebRTC {
                process.stop()
                transport?.stop()
                transport = nil
                pendingOffer = nil
                pendingAnswer = nil
                let fallback = MacScreenFallback(title: title, preferences: preferences, signaling: signaling,
                                                 relayOnly: relayOnly, refresh: displayMaximumFrameRate, display: wantedDisplay)
                self.fallback = fallback
                fallback.session.onVideoTrack = { [weak self, weak fallback] track in
                    guard let self, let fallback, self.fallback === fallback else { return }
                    onVideoTrack?(track)
                }
                fallback.session.onStreamDisplays = { [weak self, weak fallback] sizes, current in
                    guard let self, let fallback, self.fallback === fallback else { return }
                    fallback.receivedDisplays(sizes, current: current)
                    onStreamDisplays?(sizes, current)
                }
                startFallback(fallback)
                return
            }
            if let key = line.key, !offered {
                offered = true
                var offer = MacScreenRdDocument(key: key, peerCarrier: "rd_wg/1")
                let wish = MacScreenRdDocument.wish(preferences.quality, refresh: displayMaximumFrameRate ?? 60, paneWidth: paneWidthPixels)
                offer.maxWidth = wish.maxWidth
                offer.maxFps = wish.maxFps
                offer.display = wantedDisplay
                stats.targetFps = wish.maxFps
                pendingAnswer = { [weak self] answer in self?.sendAnswer(answer, sessionID: sessionID, servers: servers, to: process) }
                // The signaling socket opens on its own task: the offer waits for its `hello`.
                if signalingOpen {
                    await sendOffer(offer.text, signaling: signaling, process: process)
                } else {
                    pendingOffer = offer.text
                }
            }
            if let candidate = line.candidate {
                try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: "cmux-rd", sdpMLineIndex: 0)))
            }
            if line.listening == true {
                logger.info("cmux rd: link listening for the pane")
                attachTransport()
            }
            if let path = line.path {
                logger.info("cmux rd: path \(path.kind ?? "-", privacy: .public) \(path.rttMs ?? -1, privacy: .public) ms")
                streamPath = Self.pathLabel(path.kind)
                stats.latencyMs = path.rttMs
                if let kind = path.kind { try? await signaling.send(.path(relay: Self.isRelayed(kind))) }
            }
            if let reason = line.ended {
                end(reason)
                return
            }
        }
        if isCurrent(process), phase == .connecting || phase == .connected {
            fail(process.stderrTail.isEmpty ? L.t("macScreen.rd.viewerStopped", "The screen viewer stopped.") : process.stderrTail)
        }
    }

    private func sendAnswer(_ answer: MacScreenRdDocument, sessionID: String, servers: MacScreenRdServers, to process: any MacScreenRdWorker) {
        // The link bridge's socket lives in a 0700 directory of this user's, made off the main thread.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-rd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let relayOnly = relayOnly
        // task-owner: one answer's directory and hand-off; ends when the link has its answer
        tasks.append(Task { [weak self] in
            let made = await Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
                (try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true,
                                                          attributes: [.posixPermissions: 0o700])) != nil
            }.value
            guard let self, isCurrent(process) else { return }
            guard made else {
                fail(L.t("macScreen.rd.viewerStopped", "The screen viewer stopped."))
                return
            }
            socketDirectory = directory
            let path = directory.appendingPathComponent("s").path
            socketPath = path
            logger.info("cmux rd: link started toward the host")
            process.send(Answer(session: sessionID, peerKey: answer.key, stun: servers.stun, turn: servers.turn,
                                candidates: answer.candidates, socket: path, relayOnly: relayOnly, peerCarrier: answer.peerCarrier))
        })
    }

    @ObservationIgnored private var socketPath: String?

    private func attachTransport() {
        guard transport == nil, let socketPath else { return }
        let carrier = RemoteRdStreamCarrier(open: { try await MacScreenUnixStream.open(path: socketPath) })
        // The hub's identity is the viewer; the host does not read these claims.
        let hello = RemoteRdHello(user: "viewer", install: "mac-screen", maxDatagram: 1126, token: nil)
        guard let transport = RemoteRdStreamTransport(carrier: carrier, hello: hello, startKey: UUID().uuidString,
                                                      control: true) else {
            fail(L.t("macScreen.rd.viewerStopped", "The screen viewer stopped."))
            return
        }
        self.transport = transport
        onTransport?(transport)
        let statuses = transport.statusUpdates()
        tasks.append(Task { [weak self] in
            var askedKeyframe = false
            for await status in statuses {
                // A stopped transport's end belongs to the session it served, not to a newer one.
                guard let self, self.transport === transport, !Task.isCancelled else { return }
                switch status.state {
                case .streaming:
                    if !askedKeyframe {
                        askedKeyframe = true
                        transport.requestKeyframe()
                    }
                    if phase != .connected { phase = .connected }
                    if let rtt = status.rttMs { stats.latencyMs = Double(rtt) }
                case let .ended(why):
                    transportEnded(why)
                    return
                case .connecting, .waitingForConsent:
                    continue
                }
            }
        })
        transport.connect()
    }

    /// During negotiation the worker's typed terminal output is authoritative. Its
    /// Unix socket can close before stdout delivers the fallback decision. Closing
    /// stdin also ends a worker whose local socket could not open, while leaving
    /// its output reader alive to receive fallback, ended, or final EOF.
    func transportEnded(_ why: RemoteSessionEnd) {
        if case .connectionLost = why {
            if phase == .connecting, let process {
                process.stop()
                return
            }
            fail(L.t("macScreen.rd.lost", "The connection to the other Mac was lost."))
        } else {
            end(String(describing: why))
        }
    }

    private func end(_ reason: String) {
        logger.info("session ended: \(reason, privacy: .public)")
        let wasConnected = phase == .connected
        disconnect()
        phase = wasConnected ? .ended : .failed(message: reason, needsSignIn: false)
    }

    private func fail(_ message: String) {
        disconnect()
        phase = .failed(message: message, needsSignIn: false)
    }

    // MARK: The pane

    /// A frame reached the screen: counts it for the stats (once a second, no timer).
    func framePresented(size: CGSize) {
        setStreamFrameSize(size)
        if fallback != nil { return }
        frameWindow.frames += 1
        stats.framesDecoded += 1
        let elapsed = frameWindow.start.duration(to: .now)
        if elapsed >= .seconds(1) {
            stats.fps = Double(frameWindow.frames) / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            frameWindow = (.now, 0)
        }
    }

    public func setStreamFrameSize(_ size: CGSize) {
        if size.width >= 1, size != frameSize { frameSize = size }
        fallback?.session.setStreamFrameSize(size)
    }

    /// Input from the pane, as the remote view transport sends it.
    func send(_ event: RemoteInputEvent) {
        if let fallback { fallback.send(event) } else { transport?.send(event) }
    }

    /// The Send Keys menu: a chord as key downs and ups (modifiers first, released last).
    public func tap(_ key: VNCKeysym, modifiers: [VNCKeysym] = []) {
        let usages = (modifiers + [key]).compactMap(\.hidUsage)
        guard usages.count == modifiers.count + 1 else { return }
        for usage in usages { send(.key(usage: usage, down: true)) }
        for usage in usages.reversed() { send(.key(usage: usage, down: false)) }
    }

    public func refresh() {
        if let fallback { fallback.session.refresh() } else { transport?.requestKeyframe() }
    }

    /// A quality from the toolbar: the next session asks for it (now, when one runs).
    public func applyQuality() {
        guard phase == .connected || phase == .connecting else { return }
        restart()
    }

    public func selectDisplay(_ index: Int) {
        wantedDisplay = index
        guard phase == .connected || phase == .connecting else { return }
        restart()
    }
}
