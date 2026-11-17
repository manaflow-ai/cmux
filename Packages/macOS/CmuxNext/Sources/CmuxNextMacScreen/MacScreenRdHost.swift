import CmuxNextCompat
import CmuxNextWakeups
import CmuxScreenKit
import CoreGraphics
import Foundation
import os

/// This Mac serving one approved device hub session on cmux.rd/1
/// (plans/cmux-next/remote-desktop-mac-host.md section 7): `cmux rd serve`
/// captures, encodes and injects input, and holds the secure link; this object
/// carries its offer, answer and candidates over the session's signaling. The
/// app is the process's responsible process, so the Screen Recording and
/// Accessibility grants the person gave cmux apply to it.
///
/// The viewer chooses the protocol with its offer. A viewer that offers WebRTC
/// (the iPhone's Screen Sharing viewer, or a Mac from before cmux.rd/1) is served
/// by `ScreenStreamHost` with that offer and every later signal, so this Mac
/// stays viewable from every client the hub admits.
nonisolated final class MacScreenRdHost: Sendable {
    enum Event: Sendable, Equatable {
        /// The viewer's link is up: it sees (and, in a control session, controls) the screen.
        case viewerConnected
        /// The session ended (the viewer left, the link failed, or Stop).
        case viewerEnded(String)
        /// The host could not start (no capture permission, no display).
        case sourceFailed(String)
    }

    struct Session: Sendable {
        var id: String
        /// The name a WebRTC viewer shows for this Mac.
        var name: String
        var viewerID: String
        var viewOnly: Bool
        var servers: MacScreenRdServers
    }

    private let session: Session
    private let process = MacScreenRdProcess()
    /// The WebRTC host when the viewer offered WebRTC (nil until then, and for a cmux.rd/1 viewer).
    private let webRTC = Mutex<ScreenStreamHost?>(nil)
    /// Reads the process's lines until it ends; outlives `serve` (a connected session outlives its
    /// signaling), cancelled by `disconnectViewer`.
    private let output = Mutex<Task<Void, Never>?>(nil)
    private let handler = Mutex<(@Sendable (Event) -> Void)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-rd-host")

    /// Serves a WebRTC viewer; nil is `ScreenStreamHost` (tests replace it: no WebRTC or capture there).
    private let webRTCServer: (@Sendable (MacScreenForwardedSignaling) async throws -> Void)?

    init(session: Session, webRTCServer: (@Sendable (MacScreenForwardedSignaling) async throws -> Void)? = nil) {
        self.session = session
        self.webRTCServer = webRTCServer
    }

    /// Whether the rd process was started (a WebRTC viewer never starts it).
    var startedProcess: Bool { process.started }

    var onEvent: (@Sendable (Event) -> Void)? {
        get { handler.load() }
        set { handler.store(newValue) }
    }

    private func emit(_ event: Event) {
        handler.load()?(event)
    }

    /// Serves the session until it ends: waits for the viewer's offer, starts the host, answers with
    /// this side's session key, displays and candidates, and relays candidates both ways.
    func serve(_ signaling: any ScreenSignaling) async throws {
        var started = false
        let session = self.session
        let process = self.process
        // task-owner: the host's output for this session; ends with the process or disconnectViewer
        let output = Task { [weak self] in
            var answered = false
            var answer: MacScreenRdDocument?
            var connected = false
            for await line in process.lines {
                guard let self else { return }
                if let displays = line.displays {
                    var document = answer ?? MacScreenRdDocument(key: "")
                    document.displays = displays.compactMap { $0.count == 2 ? CGSize(width: Double($0[0]), height: Double($0[1])) : nil }
                    document.currentDisplay = line.current
                    answer = document
                }
                if let key = line.key {
                    var document = answer ?? MacScreenRdDocument(key: key)
                    document.key = key
                    answer = document
                }
                if let candidate = line.candidate {
                    if answered {
                        try? await signaling.send(.candidate(ScreenICECandidate(candidate: candidate, sdpMid: "cmux-rd", sdpMLineIndex: 0)))
                    } else {
                        answer?.candidates.append(candidate)
                    }
                }
                // The answer goes once every candidate this side will find is known.
                if line.candidatesDone == true, !answered, let document = answer {
                    answered = true
                    logger.info("cmux rd: answer sent (\(document.candidates.count, privacy: .public) candidates)")
                    do { try await signaling.send(.answer(document.text)) } catch {
                        logger.error("answer not sent: \(String(describing: error), privacy: .public)")
                    }
                }
                if line.connected == true, !connected {
                    connected = true
                    logger.info("cmux rd: viewer connected")
                    emit(.viewerConnected)
                }
                if let path = line.path, let kind = path.kind {
                    try? await signaling.send(.path(relay: MacScreenSession.isRelayed(kind)))
                }
                if let reason = line.ended {
                    emit(connected ? .viewerEnded(reason) : .sourceFailed(reason))
                    return
                }
            }
            // The process ended without saying why (it crashed, or never started). A cancel is
            // this session ending (serve returned), which the hub host already handles.
            guard !Task.isCancelled else { return }
            self?.emit(.sourceFailed(process.stderrTail.isEmpty ? "the screen host stopped" : process.stderrTail))
        }
        self.output.withLock { $0 = output }
        // Nothing to read when no rd host started (a WebRTC viewer, or a viewer that never offered).
        defer { if !process.started { output.cancel() } }
        var forward: AsyncThrowingStream<ScreenSignal, any Error>.Continuation?
        var webRTCServe: Task<Void, any Error>?
        defer { forward?.finish() }
        for try await signal in signaling.messages() {
            if let forward {
                forward.yield(signal)
                continue
            }
            switch signal {
            case let .offer(text) where !started && MacScreenRdDocument(text: text) == nil:
                // A WebRTC viewer: its offer and every later signal go to the WebRTC host.
                started = true
                let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self,
                                                                                bufferingPolicy: .bufferingOldest(512))
                continuation.yield(signal)
                forward = continuation
                let forwarded = MacScreenForwardedSignaling(base: signaling, stream: stream)
                let server = webRTCServer
                // task-owner: the WebRTC session; serve awaits it, and it ends with the signaling or disconnectViewer
                webRTCServe = Task { [self] in
                    if let server { try await server(forwarded) } else { try await serveWebRTC(forwarded) }
                }
            case let .offer(text):
                guard !started, let offer = MacScreenRdDocument(text: text) else {
                    logger.info("cmux rd: offer ignored (\(started ? "already serving" : "not a cmux.rd/1 document", privacy: .public))")
                    continue
                }
                logger.info("cmux rd: offer received (\(offer.candidates.count, privacy: .public) candidates); starting the host")
                started = true
                do { try process.start(.serve) } catch {
                    emit(.sourceFailed("the screen host could not start: \(error.localizedDescription)"))
                    return
                }
                process.send(Setup(session: session.id, peerKey: offer.key,
                                   viewer: Setup.Viewer(user: session.viewerID, install: session.viewerID),
                                   scope: session.viewOnly ? "view" : "control", stun: session.servers.stun,
                                   turn: session.servers.turn,
                                   display: offer.display.map(String.init) ?? "main", maxFps: offer.maxFps.map { min($0, 120) },
                                   maxWidth: offer.maxWidth))
                for candidate in offer.candidates { process.send(Later(candidate: candidate)) }
            case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                process.send(Later(candidate: candidate.candidate))
            case .bye:
                process.stop()
                return
            default:
                continue
            }
        }
        forward?.finish()
        try await webRTCServe?.value
    }

    /// Serves a WebRTC viewer with `ScreenStreamHost` over the forwarded signaling.
    private func serveWebRTC(_ signaling: MacScreenForwardedSignaling) async throws {
        let logger = logger
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        let host = ScreenStreamHost(name: session.name, viewOnly: session.viewOnly,
                                    backend: { ScreenCaptureBackend(log: log) }, log: log)
        host.onEvent = { [weak self] event in
            switch event {
            case .viewerConnected: self?.emit(.viewerConnected)
            case .viewerEnded: self?.emit(.viewerEnded("the WebRTC viewer left"))
            case let .sourceFailed(message): self?.emit(.sourceFailed(message))
            case .waiting, .roomLost: break
            }
        }
        webRTC.withLock { $0 = host }
        logger.info("serving a WebRTC viewer")
        try await host.serve(signaling)
    }

    /// Stop: the host stops its session (the viewer sees the link close) and exits.
    func disconnectViewer() {
        process.stop()
        output.withLock { $0 }?.cancel()
        // Closing the peer connection waits on WebRTC's threads: never on the caller's (the main actor).
        if let host = webRTC.withLock({ $0 }) { Task.detached(priority: WorkPriority.userVisible.taskPriority) { host.disconnectViewer() } }
    }

    private struct Setup: Encodable {
        struct Viewer: Encodable {
            var user: String
            var install: String
        }

        var session: String
        var peerKey: String
        var viewer: Viewer
        var scope: String
        var stun: [String]
        var turn: [MacScreenRdServers.Turn]
        var display: String
        var maxFps: Int?
        var maxWidth: Int?

        enum CodingKeys: String, CodingKey {
            case session, viewer, scope, stun, turn, display
            case peerKey = "peer_key"
            case maxFps = "max_fps"
            case maxWidth = "max_width"
        }
    }

    private struct Later: Encodable {
        var candidate: String
    }
}

/// A session's signaling with its incoming signals forwarded from another reader (the host that
/// read the viewer's first offer); sending, servers and closing go to the session's signaling.
nonisolated final class MacScreenForwardedSignaling: ScreenSignaling {
    let base: any ScreenSignaling
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>

    init(base: any ScreenSignaling, stream: AsyncThrowingStream<ScreenSignal, any Error>) {
        self.base = base
        self.stream = stream
    }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
    func send(_ signal: ScreenSignal) async throws { try await base.send(signal) }
    func iceServers() async throws -> [ICEServerConfig] { try await base.iceServers() }
    func close() { base.close() }
    var endsSessionOnClose: Bool { base.endsSessionOnClose }
}
