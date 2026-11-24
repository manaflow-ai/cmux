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
/// host runs in the Screen Sharing helper (``MacScreenHelper``), its own
/// responsible process, so the Screen Recording and Accessibility grants it
/// uses are the helper's and a grant never relaunches this app.
///
/// The viewer chooses the protocol with its offer. A viewer that offers WebRTC
/// (the iPhone's Screen Sharing viewer, or a Mac from before cmux.rd/1) is served
/// by `ScreenStreamHost` with that offer and every later signal, so this Mac
/// stays viewable from every client the hub admits. That host runs in its own
/// process too (``MacScreenStreamProcess``: this app's executable started by the
/// helper as the helper's child), so its capture and input also use the helper's
/// grants; only a build without the helper runs it in this app.
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
    private let process: any MacScreenRdWorker
    /// Stop and resource installation share one fence. Cancelling a task alone cannot revoke
    /// a buffered Rust decision or prevent a resource created after its last suspension.
    private struct Lifetime {
        var stopped = false
        var signaling: (any ScreenSignaling)?
        var output: Task<Void, Never>?
        var webRTCServe: Task<Void, any Error>?
        var webRTC: ScreenStreamHost?
        var handler: (@Sendable (Event) -> Void)?
    }
    private let lifetime = Mutex(Lifetime())
    /// The WebRTC host's process when the helper runs it (the in-app `lifetime.webRTC` otherwise).
    private let webRTCProcess = Mutex<MacScreenStreamProcess?>(nil)
    /// SECURITY: keeps the rd process's capture leaving out the app's windows only the person at this
    /// Mac may see (`CaptureExcludedWindows`), from its start until the session ends.
    private let processExclusions = Mutex<Task<Void, Never>?>(nil)
    /// The same for the WebRTC capture (`ScreenCaptureBackend.exclusionsChanged()`).
    private let webRTCExclusions = Mutex<Task<Void, Never>?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-rd-host")
    /// How long the started host may take to answer (its key and candidates); tests shorten it.
    let answerTimeout: Duration
    /// The pending no-answer deadline, from the host's start to its answer.
    private let answerDeadline: DemandTimer

    /// Serves a WebRTC viewer; nil is `ScreenStreamHost` (tests replace it: no WebRTC or capture there).
    private let webRTCServer: (@Sendable (MacScreenForwardedSignaling) async throws -> Void)?
    /// A resource-preparation boundary; tests suspend here to revoke before installation.
    private let prepareWebRTC: (@Sendable () async -> Void)?

    init(session: Session, process: any MacScreenRdWorker = MacScreenRdProcess(),
         prepareWebRTC: (@Sendable () async -> Void)? = nil,
         webRTCServer: (@Sendable (MacScreenForwardedSignaling) async throws -> Void)? = nil,
         answerTimeout: Duration = .seconds(15), clock: any Clock<Duration> = ContinuousClock()) {
        self.session = session
        self.process = process
        self.prepareWebRTC = prepareWebRTC
        self.webRTCServer = webRTCServer
        self.answerTimeout = answerTimeout
        answerDeadline = DemandTimer(owner: "mac-screen.rd-host-answer-deadline", clock: clock)
    }

    /// Whether the rd process was started (a WebRTC viewer never starts it).
    var startedProcess: Bool { process.started }

    var onEvent: (@Sendable (Event) -> Void)? {
        get { lifetime.withLock { $0.handler } }
        set { lifetime.withLock { if !$0.stopped { $0.handler = newValue } } }
    }

    private var isActive: Bool { lifetime.withLock { !$0.stopped } }

    private func emit(_ event: Event) {
        // A callback may synchronously revoke this host. Snapshot it under the fence,
        // then call outside it; an in-flight notification never owns capture resources.
        let handler = lifetime.withLock { $0.stopped ? nil : $0.handler }
        handler?(event)
    }

    /// Output starts only for an rd offer. Rust accepts Setup before emitting its key,
    /// so an answer echoes carrier metadata only after Rust validated it.
    private func readOutput(_ signaling: any ScreenSignaling, peerCarrier: String?,
                            fallbackDecision: AsyncStream<Bool>.Continuation) -> Task<Void, Never> {
        let process = self.process
        // task-owner: the host's output for this session; ends with the process or disconnectViewer
        let output = Task { [weak self] in
            defer { fallbackDecision.finish() }
            // The process ended or this session did: no more exclusion lists for it.
            defer { self?.processExclusions.withLock { $0 }?.cancel() }
            var answered = false
            var answer: MacScreenRdDocument?
            var connected = false
            for await line in process.lines {
                guard let self, isActive, !Task.isCancelled else { return }
                // Every line's kind, so a session's log shows the stage it reached (cmuxterm-hq#13721).
                logger.info("cmux rd: host line \(line.kinds, privacy: .public)")
                if line.fallbackToWebRTC {
                    fallbackDecision.yield(true)
                    return
                }
                if let displays = line.displays {
                    var document = answer ?? MacScreenRdDocument(key: "", peerCarrier: peerCarrier)
                    document.displays = displays.compactMap { $0.count == 2 ? CGSize(width: Double($0[0]), height: Double($0[1])) : nil }
                    document.currentDisplay = line.current
                    answer = document
                }
                if let key = line.key {
                    var document = answer ?? MacScreenRdDocument(key: key, peerCarrier: peerCarrier)
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
                // The answer goes once this side's host candidates are known (serve says
                // candidates_done then); reflexive and relayed ones trickle after it.
                if line.candidatesDone == true, !answered, let document = answer {
                    answered = true
                    answerDeadline.cancel()
                    logger.info("cmux rd: answer sent (\(document.candidates.count, privacy: .public) candidates)")
                    do { try await signaling.send(.answer(document.text)) } catch {
                        logger.error("answer not sent: \(String(describing: error), privacy: .public)")
                    }
                }
                if line.connected == true, !connected {
                    fallbackDecision.yield(false)
                    fallbackDecision.finish()
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
            // Its own words, never a grant's: the process (the helper in a build with one) just ended.
            let stopped = "the screen host exited without saying why"
            self?.emit(.sourceFailed(process.stderrTail.isEmpty ? stopped : "\(stopped): \(process.stderrTail)"))
        }
        let installed = lifetime.withLock { state in
            guard !state.stopped else { return false }
            state.output = output
            return true
        }
        if !installed { output.cancel() }
        return output
    }

    /// Serves the session until it ends: waits for the viewer's offer, starts the host, answers with
    /// this side's session key, displays and candidates, and relays candidates both ways.
    func serve(_ signaling: any ScreenSignaling) async throws {
        let admitted = lifetime.withLock { state in
            guard !state.stopped else { return false }
            state.signaling = signaling
            return true
        }
        guard admitted else { signaling.close(); return }
        var started = false
        var consideredFallback = false
        let session = self.session
        let process = self.process
        // The signed WebRTC offer and the local Rust decision may arrive in either order.
        // Buffer the single decision; Rust owns eligibility and its negotiation deadline.
        let (fallbackDecisions, fallbackDecision) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingOldest(1))
        var output: Task<Void, Never>?
        var forward: AsyncThrowingStream<ScreenSignal, any Error>.Continuation?
        var webRTCServe: Task<Void, any Error>?
        defer { forward?.finish() }
        for try await signal in signaling.messages() {
            guard isActive, !Task.isCancelled else { return }
            if let forward {
                forward.yield(signal)
                continue
            }
            switch signal {
            case let .offer(text) where MacScreenRdDocument(text: text) == nil:
                if started {
                    guard !consideredFallback else { continue }
                    consideredFallback = true
                    var decision = fallbackDecisions.makeAsyncIterator()
                    guard await decision.next() == true, isActive, !Task.isCancelled else { continue }
                    output?.cancel()
                    process.stop()
                }
                // A WebRTC viewer: its offer and every later signal go to the WebRTC host.
                started = true
                let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self,
                                                                                bufferingPolicy: .bufferingOldest(512))
                continuation.yield(signal)
                forward = continuation
                let forwarded = MacScreenForwardedSignaling(base: signaling, stream: stream)
                // task-owner: the WebRTC session; serve awaits it, and it ends with the signaling or disconnectViewer
                webRTCServe = lifetime.withLock { state in
                    guard !state.stopped else { return nil }
                    let task = Task { [self] in try await serveWebRTC(forwarded) }
                    state.webRTCServe = task
                    return task
                }
            case let .offer(text):
                guard !started, let offer = MacScreenRdDocument(text: text) else {
                    logger.info("cmux rd: offer ignored (\(started ? "already serving" : "not a cmux.rd/1 document", privacy: .public))")
                    continue
                }
                logger.info("cmux rd: offer received (\(offer.candidates.count, privacy: .public) candidates); starting the host")
                started = true
                do { try await process.startServe() } catch {
                    emit(.sourceFailed("the screen host could not start: \(error.localizedDescription)"))
                    return
                }
                // A stop racing Process.run may have seen no child yet. Retire that child
                // before Setup can authorize capture; never hold the fence over launch.
                guard isActive else { process.stop(); return }
                output = readOutput(signaling, peerCarrier: offer.peerCarrier, fallbackDecision: fallbackDecision)
                // The helper answers in under a second; one that has not by now never will.
                answerDeadline.schedule(after: answerTimeout) { [weak self] in self?.answerTimedOut() }
                process.send(Setup(session: session.id, peerKey: offer.key,
                                   viewer: Setup.Viewer(user: session.viewerID, install: session.viewerID),
                                   scope: session.viewOnly ? "view" : "control", stun: session.servers.stun,
                                   turn: session.servers.turn,
                                   display: offer.display.map(String.init) ?? "main", maxFps: offer.maxFps.map { min($0, 120) },
                                   maxWidth: offer.maxWidth, maxKbps: offer.maxKbps, cursor: offer.cursor,
                                   encodeProfile: offer.encodeProfile, peerCarrier: offer.peerCarrier))
                watchExclusions()
                for candidate in offer.candidates { process.send(Later(candidate: candidate)) }
            case let .candidate(candidate) where candidate.sdpMid == "cmux-rd":
                process.send(Later(candidate: candidate.candidate))
            case .bye:
                disconnectViewer()
                return
            default:
                continue
            }
        }
        forward?.finish()
        try await webRTCServe?.value
    }

    /// Serves a WebRTC viewer with `ScreenStreamHost` over the forwarded signaling: in the Screen
    /// Sharing helper's child when this build carries the helper (never this app then: macOS would
    /// check this app's grants), else in this app.
    private func serveWebRTC(_ signaling: MacScreenForwardedSignaling) async throws {
        await prepareWebRTC?()
        guard isActive, !Task.isCancelled else { return }
        if let webRTCServer {
            try await webRTCServer(signaling)
            return
        }
        if let helper = MacScreenHelper.bundled() { return try await serveWebRTCInHelper(signaling, helper: helper) }
        let logger = logger
        let log: @Sendable (String) -> Void = { line in logger.info("\(line, privacy: .public)") }
        // SECURITY: the capture leaves out the app's windows only the person at this Mac may see, and
        // follows that list within `CaptureExcludedWindows.recheck` while this session lasts.
        let host = ScreenStreamHost(name: session.name, viewOnly: session.viewOnly, backend: { [weak self] in
            let backend = ScreenCaptureBackend(log: log)
            backend.excludedWindowIDs = { CaptureExcludedWindows().windowIDs }
            let watch = Self.watchExcludedWindows { [weak backend] _ in backend?.exclusionsChanged() }
            self?.webRTCExclusions.withLock { previous in
                previous?.cancel()
                previous = watch
            }
            return backend
        }, log: log)
        host.onEvent = { [weak self] event in
            switch event {
            case .viewerConnected: self?.emit(.viewerConnected)
            case .viewerEnded: self?.emit(.viewerEnded("the WebRTC viewer left"))
            case let .sourceFailed(message): self?.emit(.sourceFailed(message))
            case .waiting, .roomLost: break
            }
        }
        let installed = lifetime.withLock { state in
            guard !state.stopped else { return false }
            state.webRTC = host
            return true
        }
        guard installed, !Task.isCancelled else { host.disconnectViewer(); return }
        // Stop may have raced the engine's own async setup after installation.
        defer { if !isActive { host.disconnectViewer() } }
        logger.info("serving a WebRTC viewer")
        defer { webRTCExclusions.withLock { $0 }?.cancel() }
        try await host.serve(signaling)
    }

    /// The WebRTC host in the helper's child (``MacScreenStreamProcess``).
    private func serveWebRTCInHelper(_ signaling: MacScreenForwardedSignaling, helper: MacScreenHelper) async throws {
        let child = MacScreenStreamProcess()
        webRTCProcess.withLock { $0 = child }
        // Stop may have run before the child was recorded, or while the helper started it.
        guard isActive, !Task.isCancelled else { child.stop(); return }
        try await child.startInHelper(helper)
        guard isActive, !Task.isCancelled else { child.stop(); return }
        // SECURITY: the child's capture leaves out the app's windows only the person at this Mac may
        // see: one reading goes on the setup, and the watch, seeded with that same reading and started
        // only once the setup is queued, sends the whole list on every later change. A watch with its
        // own first reading could send a list the setup then replaces, and never resend it.
        let excluded = CaptureExcludedWindows().windowIDs
        defer {
            webRTCExclusions.withLock { $0 }?.cancel()
            child.stop()
        }
        try await child.serve(signaling, name: session.name, viewOnly: session.viewOnly, excluded: excluded, afterSetup: {
            let watch = Self.watchExcludedWindows(from: excluded) { ids in child.exclude(ids) }
            webRTCExclusions.withLock { previous in
                previous?.cancel()
                previous = watch
            }
        }) { [weak self] event, message in
            switch event {
            case .viewerConnected: self?.emit(.viewerConnected)
            case .viewerEnded: self?.emit(.viewerEnded("the WebRTC viewer left"))
            case .sourceFailed: self?.emit(.sourceFailed(message ?? "the screen stream host failed"))
            }
        }
    }

    /// Sends the rd process the windows its capture leaves out now (it applies the list to the running
    /// capture, or at start), then the whole list again on every change until the session ends.
    private func watchExclusions() {
        let process = process
        let watch = Self.watchExcludedWindows { ids in process.send(ExcludeWindows(excludeWindows: ids.sorted())) }
        processExclusions.withLock { previous in
            previous?.cancel()
            previous = watch
        }
        // A Stop between Setup and here already cancelled the previous watch: retire this one too.
        if !isActive { watch.cancel() }
    }

    /// Reads the app's windows that ask not to be shared every `CaptureExcludedWindows.recheck` until
    /// cancelled, and calls `changed` with the list at once and on every change, in order.
    /// `from`: the list the receiver already has (it is sent again only once it changes).
    static func watchExcludedWindows(from known: Set<CGWindowID>? = nil,
                                             _ changed: @escaping @Sendable (Set<CGWindowID>) -> Void) -> Task<Void, Never> {
        // task-owner: a capture's exclusion watch; cancelled when its session's capture ends
        Task {
            var last: Set<CGWindowID>? = known
            // wakeup-allow: runs only while a screen share's capture runs (itself up to 120 frames a second),
            // never idle; cancelled when the session's capture ends. No event says a window's sharing changed.
            // concurrency-allow: an unstructured task off the main actor; each pass is one window-list read.
            while !Task.isCancelled {
                let ids = CaptureExcludedWindows().windowIDs
                if ids != last {
                    changed(ids)
                    last = ids
                }
                // wakeup-allow: the recheck period of the live capture's exclusion watch above (4 a second).
                // concurrency-allow: off the main actor; bounded by the cancel at the session's end.
                try? await Task.sleep(for: CaptureExcludedWindows.recheck)
            }
        }
    }

    /// No answer went within ``answerTimeout`` of the host's start: the session fails here
    /// (the hub hears `failed`, so the viewer's card says so) instead of serving nothing.
    private func answerTimedOut() {
        logger.error("cmux rd: the screen host gave no answer within \(String(describing: self.answerTimeout), privacy: .public); stopping it")
        process.stop()
        lifetime.withLock { $0.output }?.cancel()
        emit(.sourceFailed("the screen host did not answer"))
    }

    /// Stop: the host stops its session (the viewer sees the link close) and exits.
    func disconnectViewer() {
        let stopped = lifetime.withLock { state -> Lifetime? in
            guard !state.stopped else { return nil }
            let previous = state
            state = Lifetime(stopped: true)
            return previous
        }
        guard let stopped else { return }
        answerDeadline.cancel()
        processExclusions.withLock { $0 }?.cancel()
        webRTCExclusions.withLock { $0 }?.cancel()
        stopped.signaling?.close()
        stopped.webRTCServe?.cancel()
        process.stop()
        stopped.output?.cancel()
        // Revoke admission/capture now; only peer-connection teardown waits on WebRTC's threads.
        if let host = stopped.webRTC {
            host.revokeViewer()
            Task.detached(priority: WorkPriority.userVisible.taskPriority) { host.disconnectViewer() }
        }
        webRTCProcess.withLock { $0 }?.stop()
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
        /// The viewer's Customize wishes (nil: not sent, the host's defaults).
        var maxKbps: Int?
        var cursor: Bool?
        /// `encode_profile`: the viewer's `a=cmux-rd-encode-profile:` (`ultra`); omitted when nil, the standard profile.
        var encodeProfile: String?
        var peerCarrier: String?

        enum CodingKeys: String, CodingKey {
            case session, viewer, scope, stun, turn, display, cursor
            case peerCarrier = "peer_carrier"
            case peerKey = "peer_key"
            case maxFps = "max_fps"
            case maxWidth = "max_width"
            case maxKbps = "max_kbps"
            case encodeProfile = "encode_profile"
        }
    }

    private struct Later: Encodable {
        var candidate: String
    }

    /// `{"exclude_windows":[123,456]}`: the window ids (CGWindowID) the capture leaves out, the whole list.
    private struct ExcludeWindows: Encodable {
        var excludeWindows: [CGWindowID]

        enum CodingKeys: String, CodingKey {
            case excludeWindows = "exclude_windows"
        }
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
