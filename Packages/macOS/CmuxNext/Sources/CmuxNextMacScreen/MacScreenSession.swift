public import CmuxNextRemoteView
public import CmuxScreenKit
import CmuxNextCompat
import CmuxNextWakeups
public import CoreGraphics
import Foundation
import Network
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
    public enum Phase: Equatable {
        case connecting
        case connected
        case failed(message: String, needsSignIn: Bool)
        case ended
    }

    public struct LiveStats: Equatable, Sendable {
        public var fps = 0.0
        public var kilobytesPerSecond = 0.0
        public var latencyMs: Double?
        public var encoding = "H.264"
        public var targetFps: Int?
        public var framesReceived: Double = 0
        public var framesDecoded: Double = 0
        public var framesDropped: Double = 0
        /// The host's own once-a-second counters (cmux.rd/1 `stats`), nil until the first one or from a host that
        /// sends none: the rate it streams at, the share of packets it resent or lost, its median encode time.
        public var hostKbps: Double?
        public var lossPercent: Double?
        public var encodeMsP50: Double?
        /// The profile the host says it encodes with (`standard`, `ultra`); nil from a host too old to say. The view
        /// labels Ultra only from this, never from the quality it asked for.
        public var encodeProfile: String?
    }

    /// Why the last session failed, in the words of the side that knew. The failed card says
    /// it (``MacScreenPaneModel/failedDetail``); nil when nobody said, and the card falls back.
    public enum FailureCause: Equatable, Sendable {
        /// The host could not serve the session: its own cmux.rd/1 `ended` (`failed: <reason>`;
        /// capture, encoder or helper trouble on that Mac). `reason` may be empty.
        case host(String)
        /// This Mac's link to the host failed (`cmux rd connect`'s words: no route, a timeout).
        case link(String)
    }

    public private(set) var phase: Phase = .ended
    /// Set with a failed phase when a side said why; cleared by the next connect.
    public private(set) var failureCause: FailureCause?
    /// The secure link to the host came up in this session (`cmux rd connect` said `connected`).
    public private(set) var linkConnected = false
    public private(set) var stats = LiveStats()
    /// The decoded picture's size in pixels (zero until the first frame). Under `video.scaled`
    /// it may be smaller than `streamSize` (the host's resolution ladder).
    public private(set) var frameSize: CGSize = .zero
    /// The stream's size in pixels from the host's welcome (`width`/`height`): pointer input and
    /// the cursor are in these pixels (the pane's `RemoteViewGeometry(streamPixels:...)` falls
    /// back to `frameSize` while it is zero). Zero until the welcome.
    public private(set) var streamSize: CGSize = .zero
    /// `Direct`, `Tailnet` or `Relayed`, from the link's measured path.
    public private(set) var streamPath = "-"
    /// The carrier the rd/1 stream rides, for `debug.mac_screen`'s benchmark attestation:
    /// `link` once the link bridge's socket carries it (the only carrier this session has),
    /// nil before that and after it ends. `streamPath` is a display label, never a carrier.
    @ObservationIgnored public private(set) var transportCarrier: String?
    /// A frame stopped arriving while connected (the picture is frozen).
    public private(set) var isStalled = false
    /// The session never reconnects itself: the pane asks the hub again (``MacScreenPane``'s retry, or Try Again).
    public var isReconnecting: Bool { false }
    public var preferences: ScreenPreferences
    /// The viewer display's refresh rate; the next session asks for up to it.
    @ObservationIgnored public var displayMaximumFrameRate: Int?
    /// The pane's screen area in pixels, for Auto's stream width (read when a session offers).
    @ObservationIgnored public var paneWidthPixels: Int?
    @ObservationIgnored public var relayOnly = false
    /// Settings > cmux Remote > Screen Sharing Profile (`remote.screenSharingProfile`): `ultra`
    /// asks the host for its ultra encode profile in the next offer; nil (Balanced) asks for nothing.
    @ObservationIgnored public var encodeProfile: String?
    /// Settings > cmux Remote > Screen Sharing Frame Rate Limit (`remoteDesktop.maxFps`): the next offer asks
    /// for at most this many frames per second; nil asks for the quality's rate.
    @ObservationIgnored public var maxFpsCap: Int?
    @ObservationIgnored public var reconnectLimit = 0
    /// Relay errors for the failed card (relays are a link carrier, not reported apart).
    public var relayErrors: [ICECandidateError] { [] }
    /// A transport exists while the session runs.
    public var stream: AnyObject? { transport }

    /// The stage a connect whose deadline passed was in (the failed card names it); nil otherwise.
    public private(set) var timedOutStage: MacScreenConnectStage?
    /// What this connect waits for next (`mac_screen.state`'s `connect_stage`).
    @ObservationIgnored private(set) var connectStage: MacScreenConnectStage = .answer
    /// How long a connect may take to show its first picture.
    @ObservationIgnored var connectTimeout: Duration = .seconds(15)
    /// The pending connect deadline, from `connect()` to the first picture; tests give it a manual clock.
    @ObservationIgnored var connectDeadline = DemandTimer(owner: "mac-screen.connect-deadline")

    /// The display to show in the next session (nil: the host's main display).
    @ObservationIgnored var wantedDisplay: Int?
    /// The display a run's screen link names (a CGDirectDisplayID): every session asks for it
    /// until the person picks a display.
    @ObservationIgnored public var linkedDisplay: UInt32?
    /// Set when the host's answer lists its display ids and `linkedDisplay` is not one (the run is over): the host
    /// shows its main display. An older host lists no ids, so nothing is said.
    public private(set) var linkedDisplayGone = false
    /// This session's connect start, first frame and recent round trips (`mac_screen.state`;
    /// not observed: nothing on screen follows them).
    @ObservationIgnored var timings = MacScreenConnectTimings()
    /// The current transport's frame counter (the pane's decoder sets it), for its frame timings.
    @ObservationIgnored var frameCounter: MacScreenFrameCounter?
    /// Whether this session offers clipboard text sync (cap `clipboard.text`): the setting and the
    /// own-device rule, decided where the pane is made (`RemoteClipboardPolicy`). The host still
    /// lists the cap only when its person turned clipboard sync on.
    @ObservationIgnored public var offersClipboard = false
    /// The pane attaches its decoder to each new transport.
    @ObservationIgnored public var onTransport: ((RemoteRdStreamTransport) -> Void)?
    /// The host's displays (pixel sizes) and the one streamed, from its answer.
    @ObservationIgnored public var onStreamDisplays: (([CGSize], Int) -> Void)?
    /// A quality or display change needs a new hub session (the ticket admits once).
    @ObservationIgnored var restart: () -> Void = {}

    public let title: String
    @ObservationIgnored private let signaling: @MainActor () -> (any ScreenSignaling)?
    @ObservationIgnored private var transport: RemoteRdStreamTransport?
    @ObservationIgnored private var process: MacScreenRdProcess?
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

    public func connect() {
        disconnect()
        guard let signaling = signaling() else {
            phase = .failed(message: L.t("macScreen.rd.noTicket", "The other Mac did not approve a session yet."), needsSignIn: false)
            return
        }
        phase = .connecting
        failureCause = nil
        linkConnected = false
        timedOutStage = nil
        connectStage = .answer
        // The first decoder session in a process is the slow one: make it now, in parallel with
        // signaling and the host's capture start, not on the first keyframe.
        RemoteDecoderPrewarm.start()
        isStalled = false
        frameSize = .zero
        streamSize = .zero
        stats = LiveStats()
        timings.connectStarted(at: Date(), .now)
        frameCounter = nil
        let process = MacScreenRdProcess()
        do { try process.start(.connect) } catch {
            phase = .failed(message: L.t("macScreen.rd.noBinary", "cmux could not start its screen viewer."), needsSignIn: false)
            return
        }
        self.process = process
        // One deadline per connect: a picture cancels it, a disconnect or the next connect replaces it.
        connectDeadline.schedule(after: connectTimeout) { @MainActor [weak self, weak process] in
            guard let self, let process, self.process === process else { return }
            connectTimedOut()
        }
        signalingOpen = false
        pendingOffer = nil
        laterCandidates = []
        let sessionID = (signaling as? TicketSignaling)?.ticket.sessionID ?? UUID().uuidString
        tasks.append(Task { [weak self] in
            let servers = MacScreenRdServers((try? await signaling.iceServers()) ?? [])
            await self?.followProcess(process, signaling: signaling, sessionID: sessionID, servers: servers)
        })
        tasks.append(Task { [weak self] in await self?.followSignaling(signaling, process: process) })
    }

    /// Ends the session here (the hub hears it from the tab's viewer).
    public func disconnect(silently: Bool = false) {
        connectDeadline.cancel()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        transport?.stop()
        transport = nil
        transportCarrier = nil
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
    private func isCurrent(_ process: MacScreenRdProcess) -> Bool {
        self.process === process && !Task.isCancelled
    }

    private func followSignaling(_ signaling: any ScreenSignaling, process: MacScreenRdProcess) async {
        do {
            for try await signal in signaling.messages() {
                guard isCurrent(process) else { return }
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
                    reach(.link)
                    if !answer.displays.isEmpty { onStreamDisplays?(answer.displays, answer.currentDisplay ?? 0) }
                    if let linked = linkedDisplay {
                        let gone = answer.lacksDisplay(linked)
                        if linkedDisplayGone != gone { linkedDisplayGone = gone }
                    }
                    answered(answer)
                case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                    // The link process reads its answer first: a candidate the host trickled
                    // right behind its answer (which no longer waits for STUN and TURN) waits
                    // until the answer has gone to the process.
                    if let waiting = laterCandidates {
                        laterCandidates = waiting + [candidate.candidate]
                    } else {
                        process.send(["candidate": candidate.candidate])
                    }
                case .bye:
                    end(L.t("macScreen.rd.hostEnded", "The other Mac ended the session."))
                    return
                default:
                    continue
                }
            }
        } catch {
            if isCurrent(process), phase == .connecting {
                fail(L.t("macScreen.rd.signalingFailed", "The session could not reach the other Mac."))
            }
        }
    }

    /// The session socket said hello (it is open, so an offer can go).
    @ObservationIgnored private var signalingOpen = false
    /// This side's offer, made before the socket opened.
    @ObservationIgnored private var pendingOffer: String?
    /// The host's candidates that came before the link process had its answer (nil once it has).
    @ObservationIgnored private var laterCandidates: [String]? = []

    private func sendOffer(_ text: String, signaling: any ScreenSignaling, process: MacScreenRdProcess) async {
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

    private func followProcess(_ process: MacScreenRdProcess, signaling: any ScreenSignaling, sessionID: String,
                               servers: MacScreenRdServers) async {
        var offered = false
        for await line in process.lines {
            guard isCurrent(process) else { return }
            logger.info("cmux rd: viewer line \(line.kinds, privacy: .public)")
            if line.connected == true { reach(.frame) }
            if let key = line.key, !offered {
                offered = true
                var offer = MacScreenRdDocument(key: key)
                let wish = MacScreenRdDocument.wish(preferences.quality, refresh: displayMaximumFrameRate ?? 60, paneWidth: paneWidthPixels,
                                                    maxFps: maxFpsCap)
                offer.maxWidth = wish.maxWidth
                offer.maxFps = wish.maxFps
                offer.display = wantedDisplay
                offer.customize(preferences)
                offer.encodeProfile = encodeProfile
                offer.displayID = wantedDisplay == nil ? linkedDisplay : nil
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
            if line.connected == true { linkConnected = true }
            if line.listening == true {
                logger.info("cmux rd: link listening for the pane")
                attachTransport()
            }
            if let path = line.path {
                logger.info("cmux rd: path \(path.kind ?? "-", privacy: .public) \(path.rttMs ?? -1, privacy: .public) ms")
                streamPath = Self.pathLabel(path.kind)
                stats.latencyMs = path.rttMs
                timings.sampleRtt(path.rttMs)
                if let kind = path.kind { try? await signaling.send(.path(relay: Self.isRelayed(kind))) }
            }
            if let reason = line.ended {
                linkEnded(reason)
                return
            }
        }
        if isCurrent(process), phase == .connecting {
            fail(process.stderrTail.isEmpty ? L.t("macScreen.rd.viewerStopped", "The screen viewer stopped.") : process.stderrTail)
        }
    }

    private func sendAnswer(_ answer: MacScreenRdDocument, sessionID: String, servers: MacScreenRdServers, to process: MacScreenRdProcess) {
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
                                candidates: answer.candidates, socket: path, relayOnly: relayOnly))
            for candidate in laterCandidates ?? [] { process.send(["candidate": candidate]) }
            laterCandidates = nil
        })
    }

    @ObservationIgnored private var socketPath: String?

    private func attachTransport() {
        guard transport == nil, let socketPath else { return }
        let carrier = RemoteRdStreamCarrier(open: { try await MacScreenUnixStream.open(path: socketPath) })
        // The hub's identity is the viewer; the host does not read these claims.
        // `cursor`: the host leaves its cursor out of the pictures and the pane draws one cursor.
        // `video.scaled`: the pane draws a smaller picture into the stream's rect and its input
        // stays in stream pixels (`streamSize`), so the host may shrink it on a slow link.
        // `clock` and `ledger`: every frame's stage times, on the host's clock.
        let hello = RemoteRdHello(user: "viewer", install: "mac-screen", maxDatagram: 1126, token: nil,
                                  caps: [RemoteRdHello.cursorCap, RemoteRdHello.videoScaledCap,
                                         RemoteRdHello.clockCap, RemoteRdHello.ledgerCap])
        guard let transport = RemoteRdStreamTransport(carrier: carrier, hello: hello, startKey: UUID().uuidString,
                                                      control: true, clipboard: offersClipboard) else {
            fail(L.t("macScreen.rd.viewerStopped", "The screen viewer stopped."))
            return
        }
        self.transport = transport
        transportCarrier = "link"
        onTransport?(transport)
        let statuses = transport.statusUpdates()
        tasks.append(Task { [weak self] in
            var askedKeyframe = false
            for await status in statuses {
                // A stopped transport's end belongs to the session it served, not to a newer one.
                guard let self, self.transport === transport, !Task.isCancelled else { return }
                if let size = status.streamSize, size.width >= 1, size.height >= 1, size != streamSize { streamSize = size }
                switch status.state {
                case .streaming:
                    if !askedKeyframe {
                        askedKeyframe = true
                        transport.requestKeyframe()
                    }
                    reach(.frame)
                    if phase != .connected { phase = .connected }
                    if let rtt = status.rttMs {
                        stats.latencyMs = Double(rtt)
                        timings.sampleRtt(Double(rtt))
                    }
                case let .ended(why):
                    switch why {
                    case .connectionLost: fail(L.t("macScreen.rd.lost", "The connection to the other Mac was lost."))
                    case let .hostFailed(reason): hostFailed(reason)
                    case .hostStoppedSharing: end(L.t("macScreen.rd.hostEnded", "The other Mac ended the session."))
                    default: end(String(describing: why))
                    }
                    return
                case .connecting, .waitingForConsent:
                    continue
                }
            }
        })
        let hostStats = transport.hostStatsUpdates()
        tasks.append(Task { [weak self] in
            for await report in hostStats {
                guard let self, self.transport === transport, !Task.isCancelled else { return }
                stats.hostKbps = Double(report.kbps)
                stats.kilobytesPerSecond = Double(report.kbps) / 8
                stats.lossPercent = report.lossPercent
                stats.encodeMsP50 = report.encodeMsP50
                stats.encodeProfile = report.encodeProfile
            }
        })
        transport.connect()
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

    /// `cmux rd connect`'s `ended` line: the session ends, a failure naming who failed
    /// (``failureCause(ofEnded:)``), so the failed card says why ("link failed: the secure
    /// handshake timed out" reads "The connection to <name> failed: the secure handshake timed out").
    func linkEnded(_ reason: String) {
        switch Self.failureCause(ofEnded: reason) {
        case let .host(why)?: hostFailed(why)
        case let cause?:
            end(reason)
            if case .failed = phase { failureCause = cause }
        case nil: end(reason)
        }
    }

    /// The host said it could not serve the session: a failure even after the picture started
    /// (the host stopped, and why), never a plain Disconnected.
    private func hostFailed(_ reason: String) {
        logger.info("session ended: the host failed: \(reason, privacy: .public)")
        fail(reason)
        failureCause = .host(reason)
    }

    /// What `cmux rd connect`'s `ended` line says about who failed (cmux-rd-host `connect.rs`):
    /// `host: failed: <reason>` is the host's own failure, `link failed: <why>` this Mac's
    /// link, `failed: <error>` the link bridge's own error. Nil for every other end (the host
    /// stopped, the viewer stopped, the pane closed), which needs no explanation.
    nonisolated static func failureCause(ofEnded reason: String) -> FailureCause? {
        if reason.hasPrefix("host: ") {
            guard case let .hostFailed(why) = RemoteRdHandshake.hostEnd(String(reason.dropFirst("host: ".count))) else { return nil }
            return .host(why)
        }
        for prefix in ["link failed: ", "failed: "] where reason.hasPrefix(prefix) {
            return .link(String(reason.dropFirst(prefix.count)))
        }
        return nil
    }

    /// The connect got past a stage (never back: a late answer does not undo a link).
    func reach(_ stage: MacScreenConnectStage) {
        guard stage > connectStage else { return }
        connectStage = stage
        timings.reached(stage, at: .now)
        if stage == .shown { connectDeadline.cancel() }
    }

    /// The connect deadline passed before a picture showed: fail naming the stage it was in.
    func connectTimedOut() {
        let stage = connectStage
        guard let detail = stage.timeoutDetail(name: title) else { return }
        logger.error("cmux rd: connect timed out at \(stage.name, privacy: .public) after \(String(describing: self.connectTimeout), privacy: .public)")
        disconnect()
        timedOutStage = stage
        phase = .failed(message: detail, needsSignIn: false)
    }

    /// Whether a `path.kind` of `cmux rd` is a relayed path (the hub's `path` signal says so).
    nonisolated static func isRelayed(_ kind: String) -> Bool {
        ["turn_relay", "do_relay", "via_cloud_region"].contains(kind)
    }

    static func pathLabel(_ kind: String?) -> String {
        switch kind {
        case "direct_lan": L.t("macScreen.rd.pathLan", "Direct (local network)")
        case "direct_wan": L.t("macScreen.rd.pathDirect", "Direct")
        case "turn_relay", "do_relay", "via_cloud_region": L.t("macScreen.rd.pathRelayed", "Relayed")
        default: "-"
        }
    }

    // MARK: The pane

    /// A frame reached the screen: counts it for the stats (once a second, no timer).
    func framePresented(size: CGSize) {
        if size != frameSize, size.width >= 1 { frameSize = size }
        if connectStage != .shown { reach(.shown) }
        frameWindow.frames += 1
        stats.framesDecoded += 1
        let elapsed = frameWindow.start.duration(to: .now)
        if elapsed >= .seconds(1) {
            stats.fps = Double(frameWindow.frames) / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            frameWindow = (.now, 0)
        }
    }

    /// The current transport's counter heard from (every 15th frame, and the first): the first
    /// frame's time and the frames the other Mac numbered that never showed here. An old
    /// transport's late batch is not this session's.
    func framesCounted(_ counter: MacScreenFrameCounter) {
        guard counter === frameCounter else { return }
        let frames = counter.timings
        if let first = frames.firstPresentedAt { timings.firstFrame(at: first) }
        let dropped = Double(frames.dropped)
        if stats.framesDropped != dropped { stats.framesDropped = dropped }
    }

    public func setStreamFrameSize(_ size: CGSize) {
        if size.width >= 1, size != frameSize { frameSize = size }
    }

    /// Input from the pane, as the remote view transport sends it.
    func send(_ event: RemoteInputEvent) { transport?.send(event) }

    /// The Send Keys menu: a chord as key downs and ups (modifiers first, released last).
    public func tap(_ key: VNCKeysym, modifiers: [VNCKeysym] = []) {
        let usages = (modifiers + [key]).compactMap(\.hidUsage)
        guard usages.count == modifiers.count + 1 else { return }
        for usage in usages { send(.key(usage: usage, down: true)) }
        for usage in usages.reversed() { send(.key(usage: usage, down: false)) }
    }

    public func refresh() { transport?.requestKeyframe() }

    /// A quality from the toolbar: the next session asks for it (now, when one runs).
    public func applyQuality() {
        guard phase == .connected || phase == .connecting else { return }
        restart()
    }

    public func selectDisplay(_ index: Int) {
        wantedDisplay = index
        linkedDisplay = nil
        linkedDisplayGone = false
        guard phase == .connected || phase == .connecting else { return }
        restart()
    }

    private struct Answer: Encodable {
        var session: String
        var peerKey: String
        var stun: [String]
        var turn: [MacScreenRdServers.Turn]
        var candidates: [String]
        var socket: String
        var relayOnly: Bool

        enum CodingKeys: String, CodingKey {
            case session, stun, turn, candidates, socket
            case peerKey = "peer_key"
            case relayOnly = "relay_only"
        }
    }
}

/// The link bridge's Unix socket as the remote view transport's byte stream.
nonisolated enum MacScreenUnixStream {
    static func open(path: String) async throws -> RemoteRdByteStream {
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        // The stream's bytes: the next decoded frame waits for them.
        let queue = DispatchQueue(label: "com.cmuxterm.mac-screen.rd-socket", qos: .userInitiated)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { state in
                let resume: (Result<Void, any Error>) -> Void = { result in
                    guard !resumed.withLock({ done in defer { done = true }; return done }) else { return }
                    continuation.resume(with: result)
                }
                switch state {
                case .ready: resume(.success(()))
                case let .failed(error), let .waiting(error): resume(.failure(error))
                case .cancelled: resume(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return RemoteRdByteStream(
            read: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                        // An empty read only comes with the end of the stream or an error.
                        continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 } ?? (isComplete || error != nil ? nil : Data()))
                    }
                }
            },
            write: { bytes in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            },
            close: { connection.cancel() }
        )
    }
}

extension MacScreenSession {
    /// A fixture state for the viewer gallery (`AAMacScreenViewerGalleryTests`): the session reads as `phase` with
    /// no process or network, so the pane draws the card or the picture that state shows.
    func showPreviewState(phase: Phase, failureCause: FailureCause? = nil, linkConnected: Bool = false,
                          frameSize: CGSize = .zero, stalled: Bool = false, stats: LiveStats? = nil, path: String? = nil) {
        self.phase = phase
        if let stats { self.stats = stats }
        if let path { streamPath = path }
        self.failureCause = failureCause
        self.linkConnected = linkConnected
        self.frameSize = frameSize
        isStalled = stalled
    }
}

extension VNCKeysym {
    /// The USB HID usage of this key (the inverse of `init?(hidUsage:)`): the Send Keys menu's chords
    /// go to a cmux.rd host as physical keys.
    nonisolated var hidUsage: UInt32? {
        (UInt32(0x07_0004) ... UInt32(0x07_00E7)).first { VNCKeysym(hidUsage: $0) == self }
    }
}
