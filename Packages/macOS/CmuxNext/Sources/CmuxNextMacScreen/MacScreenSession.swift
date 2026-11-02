public import CmuxNextRemoteView
public import CmuxScreenKit
import CmuxNextCompat
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
    }

    public private(set) var phase: Phase = .ended
    public private(set) var stats = LiveStats()
    /// The streamed display's size in pixels (zero until the first frame).
    public private(set) var frameSize: CGSize = .zero
    /// `Direct`, `Tailnet` or `Relayed`, from the link's measured path.
    public private(set) var streamPath = "-"
    /// A frame stopped arriving while connected (the picture is frozen).
    public private(set) var isStalled = false
    /// This approach never reconnects on its own: Try Again asks the hub again.
    public var isReconnecting: Bool { false }
    public var preferences: ScreenPreferences
    /// The viewer display's refresh rate; the next session asks for up to it.
    @ObservationIgnored public var displayMaximumFrameRate: Int?
    @ObservationIgnored public var relayOnly = false
    @ObservationIgnored public var reconnectLimit = 0
    /// Relay errors for the failed card (relays are a link carrier, not reported apart).
    public var relayErrors: [String] { [] }
    /// A transport exists while the session runs.
    public var stream: AnyObject? { transport }

    /// The display to show in the next session (nil: the host's main display).
    @ObservationIgnored var wantedDisplay: Int?
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
        isStalled = false
        frameSize = .zero
        stats = LiveStats()
        let process = MacScreenRdProcess()
        do { try process.start(.connect) } catch {
            phase = .failed(message: L.t("macScreen.rd.noBinary", "cmux could not start its screen viewer."), needsSignIn: false)
            return
        }
        self.process = process
        let sessionID = (signaling as? TicketSignaling)?.ticket.sessionID ?? UUID().uuidString
        tasks.append(Task { [weak self] in
            let servers = MacScreenRdServers((try? await signaling.iceServers()) ?? [])
            await self?.followProcess(process, signaling: signaling, sessionID: sessionID, servers: servers)
        })
        tasks.append(Task { [weak self] in await self?.followSignaling(signaling, process: process) })
    }

    /// Ends the session here (the hub hears it from the tab's viewer).
    public func disconnect(silently: Bool = false) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        transport?.stop()
        transport = nil
        process?.stop()
        process = nil
        if let socketDirectory { try? FileManager.default.removeItem(at: socketDirectory) }
        socketDirectory = nil
        if case .connecting = phase { phase = .ended }
        if case .connected = phase { phase = .ended }
    }

    public func close() { disconnect() }

    // MARK: Signaling and the link process

    private func followSignaling(_ signaling: any ScreenSignaling, process: MacScreenRdProcess) async {
        do {
            for try await signal in signaling.messages() {
                switch signal {
                case let .answer(text):
                    guard let answer = MacScreenRdDocument(text: text) else { continue }
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
        } catch {
            if phase == .connecting {
                fail(L.t("macScreen.rd.signalingFailed", "The session could not reach the other Mac."))
            }
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
            if let key = line.key, !offered {
                offered = true
                var offer = MacScreenRdDocument(key: key)
                let wish = MacScreenRdDocument.wish(preferences.quality, refresh: displayMaximumFrameRate ?? 60)
                offer.maxWidth = wish.maxWidth
                offer.maxFps = wish.maxFps
                offer.display = wantedDisplay
                stats.targetFps = wish.maxFps
                pendingAnswer = { [weak self] answer in self?.sendAnswer(answer, sessionID: sessionID, servers: servers, to: process) }
                do { try await signaling.send(.offer(offer.text)) } catch {
                    fail(L.t("macScreen.rd.signalingFailed", "The session could not reach the other Mac."))
                    return
                }
            }
            if let candidate = line.candidate {
                try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: "cmux-rd", sdpMLineIndex: 0)))
            }
            if line.listening == true { attachTransport() }
            if let path = line.path {
                streamPath = Self.pathLabel(path.kind)
                stats.latencyMs = path.rttMs
                if let kind = path.kind { try? await signaling.send(.path(relay: kind.contains("relay"))) }
            }
            if let reason = line.ended {
                end(reason)
                return
            }
        }
        if phase == .connecting {
            fail(process.stderrTail.isEmpty ? L.t("macScreen.rd.viewerStopped", "The screen viewer stopped.") : process.stderrTail)
        }
    }

    private func sendAnswer(_ answer: MacScreenRdDocument, sessionID: String, servers: MacScreenRdServers, to process: MacScreenRdProcess) {
        // The link bridge's socket lives in a 0700 directory of this user's.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-rd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            fail(L.t("macScreen.rd.viewerStopped", "The screen viewer stopped."))
            return
        }
        socketDirectory = directory
        socketPath = directory.appendingPathComponent("s").path
        process.send(Answer(session: sessionID, peerKey: answer.key, stun: servers.stun, turn: servers.turn,
                            candidates: answer.candidates, socket: socketPath ?? ""))
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
                guard let self else { return }
                switch status.state {
                case .streaming:
                    if !askedKeyframe {
                        askedKeyframe = true
                        transport.requestKeyframe()
                    }
                    if phase != .connected { phase = .connected }
                    if let rtt = status.rttMs { stats.latencyMs = Double(rtt) }
                case let .ended(why):
                    if case .connectionLost = why {
                        fail(L.t("macScreen.rd.lost", "The connection to the other Mac was lost."))
                    } else {
                        end(String(describing: why))
                    }
                    return
                case .connecting, .waitingForConsent:
                    continue
                }
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

        enum CodingKeys: String, CodingKey {
            case session, stun, turn, candidates, socket
            case peerKey = "peer_key"
        }
    }
}

/// The link bridge's Unix socket as the remote view transport's byte stream.
nonisolated enum MacScreenUnixStream {
    static func open(path: String) async throws -> RemoteRdByteStream {
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let queue = DispatchQueue(label: "com.cmuxterm.mac-screen.rd-socket")
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

extension VNCKeysym {
    /// The USB HID usage of this key (the inverse of `init?(hidUsage:)`): the Send Keys menu's chords
    /// go to a cmux.rd host as physical keys.
    nonisolated var hidUsage: UInt32? {
        (UInt32(0x07_0004) ... UInt32(0x07_00E7)).first { VNCKeysym(hidUsage: $0) == self }
    }
}
