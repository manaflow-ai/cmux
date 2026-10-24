import CmuxVNC
import CmuxVNCDemoServer
import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import Observation
import QuartzCore

/// One live session to a computer's screen: connection state, input, quality
/// and live stats. Three kinds of target:
/// - a Mac paired as a screen stream (`VNCPairing.isStream`): the screen as
///   WebRTC video, input on data channels; reconnects on its own;
/// - a Mac paired for RFB over WebRTC (`cmux-vnc-host` without `--stream`);
/// - a VNC server reached directly (`VNCEndpoint`), or the built-in demo desktop.
///
/// Frames do not go through observation (30+ per second): `ScreenView`
/// receives them through `onFrame` / `onVideoTrack`. Use it from the main actor.
@MainActor
@Observable
public final class ScreenSession {
    public enum Phase: Equatable {
        case connecting
        case connected(VNCServerInfo)
        /// `needsSignIn`: the server wants credentials (or refused them).
        case failed(message: String, needsSignIn: Bool)
        case ended
    }

    public struct LiveStats: Equatable, Sendable {
        public var fps = 0.0
        public var kilobytesPerSecond = 0.0
        /// Round trip (stream) or update latency (RFB), in milliseconds.
        public var latencyMs: Double?
        public var decodeMs: Double?
        /// The codec and decoder ("H264 HW"), or the busiest RFB encoding.
        public var encoding = "-"
        /// The frame rate the Mac streams at (60, or up to 120 when both
        /// displays can); nil from a Mac that does not say (stream only).
        public var targetFps: Int?
        /// A screen stream's totals since it started (WebRTC's inbound video):
        /// frames that arrived, were decoded, and were dropped before showing.
        public var framesReceived: Double = 0
        public var framesDecoded: Double = 0
        public var framesDropped: Double = 0
    }

    public let title: String
    public private(set) var phase = Phase.connecting {
        didSet { resumeWaiters() }
    }
    @ObservationIgnored private var phaseWaiters: [CheckedContinuation<Bool, Never>] = []
    public private(set) var stats = LiveStats()
    /// The remote screen's pixel size (the streamed display, or the framebuffer).
    public private(set) var frameSize = CGSize.zero
    public var preferences: ScreenPreferences
    public var credentials: VNCCredentials
    /// Automatic reconnects after a stream drops: how many tries (0 turns them
    /// off), backing off 0, 1, 2, 4, 8 s, before the session fails.
    @ObservationIgnored public var reconnectLimit = 5

    @ObservationIgnored public var onFrame: ((VNCFrame) -> Void)?
    /// Opt-in timing log (input → frame); nil (off) unless the app sets one.
    @ObservationIgnored public var perf: ScreenPerfLog?
    /// The session's latest counters (for the perf log).
    @ObservationIgnored public private(set) var clientStats = VNCSessionStats()
    @ObservationIgnored public var onCursor: ((VNCCursor) -> Void)?
    /// The server's own screen layout (ExtendedDesktopSize), when it sends one.
    @ObservationIgnored public var onScreens: (([CGRect]) -> Void)?
    @ObservationIgnored private var client: VNCClient?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let endpoint: VNCEndpoint?
    /// Set for a Mac paired over WebRTC.
    @ObservationIgnored private let pairing: VNCPairing?
    /// Set for a screen stream whose signaling the app supplies per connect
    /// (a device hub session's ticket): nil when there is none to connect with.
    @ObservationIgnored private let makeSignaling: (@MainActor () -> (any ScreenSignaling)?)?
    @ObservationIgnored private var demo: VNCDemoServer?
    @ObservationIgnored private var statsWindow = (start: CACurrentMediaTime(), frames: 0, bytes: 0)
    @ObservationIgnored private var heldButtons: VNCButtons = []
    /// Set for a Mac paired as a screen stream (WebRTC video + input channel).
    @ObservationIgnored public private(set) var stream: ScreenStreamViewer?
    @ObservationIgnored public var onVideoTrack: ((VideoTrackBox) -> Void)?
    /// Stream displays (sizes) and the one streaming.
    @ObservationIgnored public var onStreamDisplays: (([CGSize], Int) -> Void)?
    /// "Direct" or "Relay" once WebRTC picks a path.
    public private(set) var streamPath = "WebRTC"
    /// The stream dropped and is coming back on its own.
    public private(set) var isReconnecting = false
    /// The connection stalled (ICE disconnected): no picture is coming,
    /// though WebRTC has not given up yet. Cleared when it recovers.
    public private(set) var isStalled = false
    /// `close()` ran: the session never connects again.
    @ObservationIgnored public private(set) var isClosed = false
    /// When the current run of reconnects started (the give-up clock).
    @ObservationIgnored private var reconnectStarted: Date?
    /// Reconnects stop once they have tried this long, whatever `reconnectLimit` says.
    public nonisolated static let reconnectDeadline: TimeInterval = 45
    /// The TURN relays' errors in the current connection (refused
    /// credentials, unreachable), so a failure can say why; cleared on connect.
    public private(set) var relayErrors: [ICECandidateError] = []
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    public var isStream: Bool { pairing?.isStream == true || makeSignaling != nil }
    /// Screen streams use the TURN relay only (ICE policy `relay`), to check
    /// the relay path; applies from the next `connect()`. Off by default.
    @ObservationIgnored public var relayOnly = false
    /// An app's own identifier for what this session opened (a saved host),
    /// so it can keep the session's preferences afterwards.
    @ObservationIgnored public var hostID: UUID?
    /// The most frames per second the display showing this session refreshes
    /// at (`NSScreen.maximumFramesPerSecond`), told to a screen stream's Mac
    /// on connect and whenever it changes: with Auto or Smooth Motion the
    /// Mac streams at up to 120 fps when its own display can too. Nil (an
    /// app that never sets it) keeps the stream at 60.
    @ObservationIgnored public var displayMaximumFrameRate: Int? {
        didSet {
            guard let fps = displayMaximumFrameRate, fps != oldValue else { return }
            stream?.setDisplayFrameRate(fps)
        }
    }
    /// The remote pointer in framebuffer pixels.
    @ObservationIgnored public private(set) var pointer = CGPoint(x: 100, y: 100)

    /// A VNC server reached directly (LAN, tailnet).
    public init(title: String, endpoint: VNCEndpoint, credentials: VNCCredentials = VNCCredentials(),
                preferences: ScreenPreferences = ScreenPreferences()) {
        self.title = title
        self.endpoint = endpoint
        self.credentials = credentials
        self.preferences = preferences
        pairing = nil
        makeSignaling = nil
    }

    /// A Mac paired over WebRTC: a screen stream host (`cmux-vnc-host
    /// --capture`, `cmux-screen-host`) or RFB over WebRTC (`cmux-vnc-host`).
    public init(title: String, pairing: VNCPairing, credentials: VNCCredentials = VNCCredentials(),
                preferences: ScreenPreferences = ScreenPreferences()) {
        self.title = title
        endpoint = VNCEndpoint(host: "webrtc", port: 1)
        self.pairing = pairing
        self.credentials = credentials
        self.preferences = preferences
        makeSignaling = nil
    }

    /// A screen stream whose signaling the app supplies: each `connect()`
    /// asks `signaling` for the connection to use (a device hub session's
    /// ``TicketSignaling``, which admits once). Nil fails the connect, so a
    /// dropped session does not reconnect on its own unless the app has a
    /// new one ready.
    public init(title: String, preferences: ScreenPreferences = ScreenPreferences(),
                signaling: @escaping @MainActor () -> (any ScreenSignaling)?) {
        self.title = title
        endpoint = VNCEndpoint(host: "webrtc", port: 1)
        pairing = nil
        credentials = VNCCredentials()
        self.preferences = preferences
        makeSignaling = signaling
    }

    /// "WebRTC" or "Direct", for the stats line.
    public var pathLabel: String { isStream ? "Video · \(streamPath)" : (pairing != nil ? "WebRTC" : (isDemo ? "Loopback" : "Direct")) }

    /// The built-in demo desktop on a loopback server in this app.
    public init(demoPreferences: ScreenPreferences = ScreenPreferences()) {
        title = "Demo desktop"
        endpoint = nil
        credentials = VNCCredentials()
        preferences = demoPreferences
        pairing = nil
        makeSignaling = nil
    }

    public var isDemo: Bool { endpoint == nil }

    /// Connects (again): any running connection is replaced.
    public func connect() {
        guard !isClosed else { return }
        disconnect(silently: true)
        phase = .connecting
        if let makeSignaling {
            guard let signaling = makeSignaling() else {
                phase = .failed(message: "There is no session to connect with.", needsSignIn: false)
                return
            }
            connectStream(ScreenStreamViewer(signaling: signaling, relayOnly: relayOnly), name: title)
            return
        }
        if let pairing, pairing.isStream {
            connectStream(ScreenStreamViewer(pairing: pairing, relayOnly: relayOnly), name: pairing.name)
            return
        }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            var target = endpoint
            if target == nil {
                let server = demo ?? VNCDemoServer(configuration: .init(width: 1440, height: 900, name: "cmux VNC demo desktop"))
                demo = server
                guard let port = try? await server.start() else {
                    phase = .failed(message: "The demo desktop could not start.", needsSignIn: false)
                    return
                }
                target = VNCEndpoint(host: "127.0.0.1", port: port)
            }
            guard let target else { return }
            let options = VNCSessionOptions(credentials: credentials, localCursor: preferences.localCursor)
            start(VNCClient(endpoint: target, options: options, transport: pairing.map { WebRTCRFBTransport(pairing: $0) }))
        })
    }

    private func start(_ client: VNCClient) {
        self.client = client
        statsWindow = (CACurrentMediaTime(), 0, 0)
        tasks.append(Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case let .connected(info):
                    phase = .connected(info)
                    pointer = CGPoint(x: info.width / 2, y: info.height / 2)
                case let .cursor(cursor):
                    onCursor?(cursor)
                case let .screens(screens):
                    onScreens?(screens.count > 1 ? screens.map(\.frame) : [])
                case let .disconnected(error):
                    if let error {
                        phase = .failed(message: Self.message(for: error), needsSignIn: error.needsCredentials)
                    } else {
                        phase = .ended
                    }
                case .bell, .clipboard:
                    break
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await frame in client.frames {
                guard let self else { return }
                frameSize = CGSize(width: frame.width, height: frame.height)
                clientStats = await client.stats
                onFrame?(frame)
                await updateStats(client)
            }
        })
        Task { await client.connect() }
    }

    // MARK: Stream

    private func connectStream(_ viewer: ScreenStreamViewer, name: String) {
        stream = viewer
        if let reconnectStarted { viewer.openTimeout = Self.attemptTimeout(elapsed: Date().timeIntervalSince(reconnectStarted)) }
        relayErrors = []
        isStalled = false
        stats.targetFps = nil
        viewer.onStall = { [weak self, weak viewer] stalled in
            Task { @MainActor in
                guard let self, self.stream === viewer else { return }
                self.isStalled = stalled
                // The give-up clock starts when the picture stops, not when WebRTC
                // later declares the connection failed; it resets if it recovers.
                if stalled, self.reconnectStarted == nil { self.reconnectStarted = Date() }
                if !stalled, !self.isReconnecting { self.reconnectStarted = nil }
            }
        }
        viewer.onICEError = { [weak self] error in
            guard error.isTURN else { return }
            Task { @MainActor in self?.relayErrors.append(error) }
        }
        viewer.onVideo = { [weak self] box in Task { @MainActor in self?.onVideoTrack?(box) } }
        viewer.onDisplays = { [weak self, weak viewer] message in
            Task { @MainActor in
                guard let self, self.stream === viewer else { return }
                let sizes = (message.displays ?? []).map { CGSize(width: $0.w, height: $0.h) }
                if let fps = message.fps, self.stats.targetFps != fps { self.stats.targetFps = fps }
                self.onStreamDisplays?(sizes, message.current ?? 0)
            }
        }
        viewer.onPath = { [weak self] path in Task { @MainActor in self?.streamPath = path } }
        viewer.onState = { [weak self, weak viewer] message in
            Task { @MainActor in
                guard let self, let message, self.stream === viewer else { return }
                self.streamDropped(message)
            }
        }
        tasks.append(Task { [weak self] in
            do {
                try await viewer.connect()
                // A connect that finished after this session moved on (closed, disconnected) changes nothing.
                guard let self, !Task.isCancelled, stream === viewer else { return }
                reconnectAttempts = 0
                reconnectStarted = nil
                isReconnecting = false
                // The display's rate first: the Mac then sets up the quality at the agreed rate.
                if let fps = displayMaximumFrameRate { viewer.setDisplayFrameRate(fps) }
                viewer.setQuality(preferences.quality)
                phase = .connected(VNCServerInfo(width: 0, height: 0, name: name, nativeFormat: .bgrx,
                                                 protocolMinor: 8, securityType: 0))
                await pollStreamStats(viewer)
            } catch {
                guard let self, stream === viewer else { return }
                if isReconnecting {
                    streamDropped("Could not reach the Mac: \(error)")
                } else {
                    phase = .failed(message: "Could not reach the Mac: \(error)", needsSignIn: false)
                }
            }
        })
    }

    /// The stream ended without the user closing it: reconnect a few times
    /// (backing off) before showing the error.
    /// How long one try may wait: 30 s, or what is left of the reconnect
    /// deadline (at least 1 s), so the last try never runs past it.
    public nonisolated static func attemptTimeout(elapsed: TimeInterval) -> TimeInterval {
        max(1, min(30, reconnectDeadline - elapsed))
    }

    /// Whether reconnecting stops: after `limit` tries, or once it has tried for ``reconnectDeadline`` seconds.
    public nonisolated static func givesUp(attempts: Int, limit: Int, elapsed: TimeInterval) -> Bool {
        attempts >= limit || elapsed > reconnectDeadline
    }

    private func streamDropped(_ message: String) {
        isStalled = false
        let started = reconnectStarted ?? Date()
        reconnectStarted = started
        guard !Self.givesUp(attempts: reconnectAttempts, limit: reconnectLimit, elapsed: Date().timeIntervalSince(started)) else {
            reconnectStarted = nil
            // Giving up: the dropped stream's room socket would keep reconnecting.
            stream?.close()
            stream = nil
            isReconnecting = false
            phase = .failed(message: message, needsSignIn: false)
            return
        }
        reconnectAttempts += 1
        isReconnecting = true
        phase = .connecting
        let delay = reconnectAttempts == 1 ? 0 : min(pow(2, Double(reconnectAttempts - 2)), 8)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay)) // reconnect backoff
            guard !Task.isCancelled, let self, isReconnecting else { return }
            connect()
        }
    }

    /// Connects again under the reconnect policy: a failed attempt retries
    /// with backoff before the error shows. For a change that needs a new
    /// connection (the relay setting), where the host may still be dropping
    /// the old one.
    public func reconnect() {
        guard !isClosed else { return }
        reconnectStarted = nil
        reconnectTask?.cancel()
        reconnectAttempts = 0
        isReconnecting = true
        connect()
    }

    /// The app came back to the foreground: a stream that dropped while it
    /// was suspended reconnects right away.
    public func resumeIfNeeded() {
        guard isStream, !isClosed else { return }
        switch phase {
        case .failed(_, false), .ended:
            reconnectAttempts = 0
            isReconnecting = true
            connect()
        default:
            break
        }
    }

    /// Applies `preferences.quality` to the running stream.
    public func applyQuality() {
        stream?.setQuality(preferences.quality)
    }

    /// WebRTC's own numbers, once a second, for the stats line.
    private func pollStreamStats(_ viewer: ScreenStreamViewer) async {
        var lastBytes = 0.0
        var lastTime = CACurrentMediaTime()
        while !Task.isCancelled, stream === viewer {
            try? await Task.sleep(for: .seconds(1)) // stats sampling period
            let video = await viewer.videoStats()
            let now = CACurrentMediaTime()
            var next = stats
            next.fps = video.fps ?? 0
            next.kilobytesPerSecond = (video.bytesReceived - lastBytes) / 1024 / max(now - lastTime, 0.001)
            next.latencyMs = video.rttMs
            next.encoding = [video.codec, video.decoder == "VideoToolbox" ? "HW" : video.decoder].compactMap { $0 }.joined(separator: " ")
            next.framesReceived = video.framesReceived
            next.framesDecoded = video.framesDecoded
            next.framesDropped = video.framesDropped
            stats = next
            lastBytes = video.bytesReceived
            lastTime = now
        }
    }

    /// Streams display `index` (the Mac crops to it).
    public func selectDisplay(_ index: Int) {
        stream?.send(ScreenInput(t: "display", i: index))
    }

    /// The pointer as a fraction of the streamed display.
    private func normalized(_ point: CGPoint) -> (Double, Double) {
        (Double(point.x / max(frameSize.width, 1)), Double(point.y / max(frameSize.height, 1)))
    }

    /// The video's pixel size (the streamed display).
    public func setStreamFrameSize(_ size: CGSize) {
        frameSize = size
    }

    /// Ends the connection; `silently` keeps the phase (no "ended" card).
    public func disconnect(silently: Bool = false) {
        if !silently {
            reconnectTask?.cancel()
            isReconnecting = false
        }
        for task in tasks { task.cancel() }
        tasks.removeAll()
        if let client { Task { await client.disconnect() } }
        client = nil
        // Closing a peer connection waits on WebRTC's threads (TURN
        // deallocation can take seconds): never on the main actor.
        if let stream { Task.detached { stream.close() } }
        stream = nil
        stats.targetFps = nil
        if !silently { phase = .ended }
    }

    /// Stops everything, including the demo server.
    public func close() {
        disconnect()
        isClosed = true
        demo?.stop()
        demo = nil
    }

    private func updateStats(_ client: VNCClient) async {
        statsWindow.frames += 1
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindow.start
        guard elapsed >= 0.5 else { return }
        let snapshot = await client.stats
        var next = stats
        next.fps = Double(statsWindow.frames) / elapsed
        next.kilobytesPerSecond = Double(snapshot.bytesReceived - statsWindow.bytes) / elapsed / 1024
        next.latencyMs = snapshot.lastUpdateLatencyMs
        next.decodeMs = snapshot.lastDecodeMs
        next.encoding = snapshot.rectanglesByEncoding.max { $0.value < $1.value }.map { Self.encodingName($0.key) } ?? "-"
        stats = next
        statsWindow = (now, 0, snapshot.bytesReceived)
    }

    /// Resumes when the session connects (true) or fails or ends (false).
    public func waitUntilConnected() async -> Bool {
        switch phase {
        case .connected: return true
        case .failed, .ended: return false
        case .connecting: break
        }
        return await withCheckedContinuation { phaseWaiters.append($0) }
    }

    private func resumeWaiters() {
        let connected: Bool
        switch phase {
        case .connecting: return
        case .connected: connected = true
        case .failed, .ended: connected = false
        }
        let waiters = phaseWaiters
        phaseWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: connected) }
    }

    // MARK: Input

    /// Moves the pointer to framebuffer point `point`.
    public func movePointer(to point: CGPoint) {
        if let stream {
            pointer = clamp(point)
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.rawValue))
            return
        }
        guard let client else { return }
        pointer = clamp(point)
        let target = pointer
        Task { await client.movePointer(x: Int(target.x), y: Int(target.y)) }
    }

    public func press(_ button: VNCButtons, down: Bool) {
        if let stream {
            if down { perf?.input("press"); heldButtons.insert(button) } else { heldButtons.remove(button) }
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.rawValue))
            return
        }
        guard let client else { return }
        if down { perf?.input("press") }
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        Task { await client.button(button, down: down) }
    }

    public func click(_ button: VNCButtons = .left) {
        if let stream {
            perf?.input(button == .right ? "right-click" : "click")
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.union(button).rawValue))
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.rawValue))
            return
        }
        guard let client else { return }
        perf?.input(button == .right ? "right-click" : "click")
        Task {
            await client.button(button, down: true)
            await client.button(button, down: false)
        }
    }

    public func scroll(dx: Int, dy: Int) {
        if let stream, dx != 0 || dy != 0 {
            perf?.input("scroll")
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "scroll", x: x, y: y, dx: dx, dy: dy))
            return
        }
        guard let client, dx != 0 || dy != 0 else { return }
        perf?.input("scroll")
        Task { await client.scroll(dx: dx, dy: dy) }
    }

    public func type(_ text: String, modifiers: [VNCKeysym] = []) {
        if let stream {
            perf?.input("type")
            if modifiers.isEmpty {
                stream.send(ScreenInput(t: "text", s: text))
            } else {
                for character in text {
                    stream.send(ScreenInput(t: "chord", k: VNCKeysym(character: character).rawValue, m: modifiers.map(\.rawValue)))
                }
            }
            return
        }
        guard let client else { return }
        perf?.input("type")
        if modifiers.isEmpty {
            Task { await client.type(text) }
        } else {
            Task {
                for character in text { await client.chord(modifiers, VNCKeysym(character: character)) }
            }
        }
    }

    public func tap(_ key: VNCKeysym, modifiers: [VNCKeysym] = []) {
        if let stream {
            perf?.input(modifiers.isEmpty ? "key" : "shortcut")
            stream.send(ScreenInput(t: "chord", k: key.rawValue, m: modifiers.map(\.rawValue)))
            return
        }
        guard let client else { return }
        perf?.input(modifiers.isEmpty ? "key" : "shortcut")
        Task { await client.chord(modifiers, key) }
    }

    public func key(_ key: VNCKeysym, down: Bool) {
        if let stream {
            stream.send(ScreenInput(t: "key", k: key.rawValue, d: down))
            return
        }
        guard let client else { return }
        Task { await client.key(key, down: down) }
    }

    public func refresh() {
        if let stream {
            stream.send(ScreenInput(t: "refresh"))
            return
        }
        guard let client else { return }
        Task { await client.refresh() }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), max(0, frameSize.width - 1)), y: min(max(0, point.y), max(0, frameSize.height - 1)))
    }

    public static func message(for error: RFBError) -> String {
        switch error {
        case .passwordRequired: "This computer asks for a VNC password."
        case .credentialsRequired: "This Mac asks for an account user name and password."
        case let .authenticationFailed(reason): reason.isEmpty ? "The user name or password was not accepted." : reason
        case .connectionClosed: "The computer closed the connection."
        case let .transport(detail): "Could not reach the computer. \(detail)"
        case let .noSupportedSecurityType(types): "This server needs a sign-in method this app does not support yet (\(types))."
        case let .unsupportedProtocolVersion(version): "Not a VNC server (\(version))."
        case let .protocolViolation(detail): "The server sent something unexpected: \(detail)."
        }
    }

    static func encodingName(_ raw: Int32) -> String {
        switch RFBEncoding(rawValue: raw) {
        case .raw: "Raw"
        case .copyRect: "CopyRect"
        case .rre: "RRE"
        case .hextile: "Hextile"
        case .zlib: "Zlib"
        case .zrle: "ZRLE"
        default: "#\(raw)"
        }
    }
}

/// Identity, so an app can present a session with `.fullScreenCover(item:)`.
extension ScreenSession: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
