import CmuxVNC
import CoreGraphics
import CoreVideo
import Foundation
import Network
import VideoToolbox
import WebRTC

/// Viewer → host input and control on the `input` data channel. Pointer
/// coordinates are normalized (0...1) within the display being streamed.
public struct ScreenInput: Codable, Sendable {
    /// move, scroll, key, chord, text, display, refresh
    public var t: String
    public var x: Double?
    public var y: Double?
    /// RFB button mask (1 left, 2 middle, 4 right).
    public var b: UInt8?
    public var dx: Int?
    public var dy: Int?
    /// X11 keysym.
    public var k: UInt32?
    public var d: Bool?
    public var s: String?
    public var i: Int?
    /// Modifier keysyms for `chord`.
    public var m: [UInt32]?

    public init(t: String, x: Double? = nil, y: Double? = nil, b: UInt8? = nil, dx: Int? = nil, dy: Int? = nil,
                k: UInt32? = nil, d: Bool? = nil, s: String? = nil, i: Int? = nil, m: [UInt32]? = nil) {
        self.t = t; self.x = x; self.y = y; self.b = b; self.dx = dx; self.dy = dy
        self.k = k; self.d = d; self.s = s; self.i = i; self.m = m
    }
}

/// The viewer's choice of stream quality. `auto` leaves the trade-offs to
/// WebRTC (sharp text first); the fixed presets hold a resolution, frame
/// rate and bitrate even when the network cannot carry them, which shows
/// as lag and stalls instead of blur.
public enum ScreenQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, smooth, low, medium, high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .smooth: "Smooth Motion"
        case .low: "Fixed Low (720p)"
        case .medium: "Fixed Medium (1080p)"
        case .high: "Fixed High (Full)"
        }
    }

    struct Settings: Equatable {
        var degradation: RTCDegradationPreference
        var maxBitrate: Int
        var minBitrate: Int?
        var maxFramerate: Int
        var scaleDown: Double
    }

    /// The sender's encoding for a display `sourceHeight` pixels tall (0: unknown).
    func settings(sourceHeight: Int) -> Settings {
        func scale(to height: Int) -> Double { sourceHeight > height ? Double(sourceHeight) / Double(height) : 1 }
        switch self {
        case .auto: return Settings(degradation: .maintainResolution, maxBitrate: 12_000_000, maxFramerate: 60, scaleDown: 1)
        case .smooth: return Settings(degradation: .maintainFramerate, maxBitrate: 12_000_000, maxFramerate: 60, scaleDown: 1)
        case .low: return Settings(degradation: .disabled, maxBitrate: 1_500_000, minBitrate: 1_500_000, maxFramerate: 30, scaleDown: scale(to: 720))
        case .medium: return Settings(degradation: .disabled, maxBitrate: 4_000_000, minBitrate: 4_000_000, maxFramerate: 30, scaleDown: scale(to: 1080))
        case .high: return Settings(degradation: .disabled, maxBitrate: 10_000_000, minBitrate: 10_000_000, maxFramerate: 60, scaleDown: 1)
        }
    }
}

/// Host → viewer: the displays and which one is streaming.
public struct ScreenHostMessage: Codable, Sendable {
    public struct Display: Codable, Sendable, Equatable {
        public var w: Int
        public var h: Int
    }

    public var t: String
    public var displays: [Display]?
    public var current: Int?
    public var name: String?
}

/// Where a screen stream's pictures come from and where its input goes.
/// `VNCLoopbackBackend` reads this Mac's Screen Sharing (no permissions);
/// `ScreenCaptureBackend` uses ScreenCaptureKit and CGEvent (Screen
/// Recording and Accessibility, granted to the host app).
public protocol ScreenBackend: AnyObject, Sendable {
    /// Starts producing frames. `frame` gets each new picture (full display,
    /// or a crop of it); `displays` the display sizes and the streaming one.
    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void,
               displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws
    func select(display index: Int)
    func handle(_ input: ScreenInput)
    func stop()
}

/// The Mac side of a screen stream: holds the room open, answers each
/// viewer with the screen as a WebRTC video track (hardware H.264), and
/// hands the viewer's input to the backend. One viewer at a time.
public final class ScreenStreamHost: @unchecked Sendable {
    // @unchecked: `session` is behind `lock`; a session's fields are touched
    // from its own tasks and the backend's callback queue.
    private final class Session: @unchecked Sendable {
        let link: VNCPeerLink
        let video = ScreenVideoSource()
        let backend: any ScreenBackend
        var tasks: [Task<Void, Never>] = []
        let lock = NSLock()
        var last: (buffer: CVPixelBuffer, crop: CGRect)?
        var lastPush = DispatchTime.now()
        var displays: [CGSize] = []
        var current = 0
        var quality = ScreenQuality.auto
        /// The data channel opened: from here on only WebRTC ends the session.
        var opened = false
        init(link: VNCPeerLink, backend: any ScreenBackend) {
            self.link = link
            self.backend = backend
        }
    }

    /// What an app shows about the host: whether the room is open and
    /// whether a viewer is watching. Optional; the CLI host only logs.
    public enum Event: Sendable, Equatable {
        /// The room is open and waiting for a viewer.
        case waiting
        /// The room connection dropped; the host retries on its own.
        case roomLost(String)
        /// A viewer's data channel opened: it sees the screen and controls it.
        case viewerConnected
        /// The viewer's session ended (it left, dropped, or `disconnectViewer()`).
        case viewerEnded
        /// The screen source could not start (for ScreenCaptureKit: Screen Recording is not granted).
        case sourceFailed(String)
    }

    public let pairing: VNCPairing
    private let makeBackend: @Sendable () -> any ScreenBackend
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var session: Session?
    /// Called from the host's tasks with each `Event` (any thread).
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.withLock { eventSink } }
        set { lock.withLock { eventSink = newValue } }
    }
    private var eventSink: (@Sendable (Event) -> Void)?

    public init(pairing: VNCPairing, backend: @escaping @Sendable () -> any ScreenBackend,
                log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.pairing = pairing
        makeBackend = backend
        self.log = log
    }

    /// The loopback Screen Sharing backend (V1).
    public convenience init(pairing: VNCPairing, target: VNCEndpoint, credentials: VNCCredentials,
                            log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.init(pairing: pairing, backend: { VNCLoopbackBackend(target: target, credentials: credentials, log: log) }, log: log)
    }

    public func run() async {
        var delay = 1.0
        while !Task.isCancelled {
            do {
                try await serveRoom()
                delay = 1
            } catch {
                log("room connection lost: \(error); retrying in \(Int(delay)) s")
                emit(.roomLost("\(error)"))
            }
            try? await Task.sleep(for: .seconds(delay)) // reconnect backoff
            delay = min(delay * 2, 30)
        }
        endSession()
    }

    /// Ends the current viewer's session (it may connect again with the link).
    public func disconnectViewer() {
        endSession()
    }

    private func emit(_ event: Event) {
        lock.withLock { eventSink }?(event)
    }

    private func serveRoom() async throws {
        let socket = SignalSocket(pairing: pairing, role: "host")
        defer { socket.close() }
        for try await message in socket.messages() {
            switch message.type {
            case "hello":
                log("waiting for a viewer in room \(pairing.room.prefix(8))…")
                emit(.waiting)
            case "offer":
                guard let sdp = message.sdp else { continue }
                try await accept(offer: sdp, socket: socket)
            case "candidate": await lock.withLock({ session?.link })?.add(candidate: message)
            case "peer-left":
                // The viewer's room connection dropped. A connected session
                // lives on (WebRTC reports its own end); a half-open one ends.
                let current = lock.withLock { session }
                if let current, current.lock.withLock({ current.opened }) {
                    log("viewer's room connection dropped; the stream continues")
                } else {
                    log("viewer left")
                    endSession()
                }
            default: break
            }
        }
    }

    private func accept(offer sdp: String, socket: SignalSocket) async throws {
        endSession()
        let link = try VNCPeerLink(iceServers: try await SignalSocket.iceServers(pairing), preferStreamRelays: false)
        let session = Session(link: link, backend: makeBackend())
        lock.withLock { self.session = session }
        session.tasks.append(Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await socket.send(message)
                case .open: self?.start(session)
                case let .message(data): self?.handleInput(data, session: session)
                case .closed: self?.endSession(ifCurrent: session)
                case let .path(local, remote):
                    self?.log("path: this Mac \(local) ↔ viewer \(remote)\(local == "relay" || remote == "relay" ? " (TURN relay)" : " (direct)")")
                case .video: break
                }
            }
        })
        let answer = try await link.answer(offer: sdp, video: session.video)
        try await socket.send(SignalMessage(type: "answer", sdp: answer))
        log("viewer offered; streaming answer sent")
    }

    private func start(_ session: Session) {
        session.lock.withLock { session.opened = true }
        log("channel open; starting \(type(of: session.backend))")
        emit(.viewerConnected)
        session.tasks.append(Task { [weak self] in
            do {
                try await session.backend.start(frame: { [weak self] buffer, crop in
                    self?.push(buffer, crop: crop, session: session)
                }, displays: { [weak self] sizes, current in
                    session.lock.withLock {
                        session.displays = sizes
                        session.current = current
                    }
                    self?.sendDisplays(session)
                    self?.applyQuality(session)
                })
            } catch {
                self?.log("screen source failed: \(error)")
                self?.emit(.sourceFailed("\(error)"))
            }
        })
        // Every 3 s: what the encoder is doing (codec, hardware, fps, limits).
        session.tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3)) // sampling period
                guard let self else { return }
                log("video: \(await session.link.outboundVideoSummary())")
            }
        })
        // Idle refresh: capture sends nothing while the screen is still, but a
        // lost keyframe or a quality step needs a frame to encode.
        session.tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500)) // idle refresh period
                guard let self else { return }
                let stale = session.lock.withLock { () -> (CVPixelBuffer, CGRect)? in
                    guard let last = session.last, DispatchTime.now().uptimeNanoseconds - session.lastPush.uptimeNanoseconds > 450_000_000 else { return nil }
                    return (last.buffer, last.crop)
                }
                if let stale { push(stale.0, crop: stale.1, session: session) }
            }
        })
    }

    private func push(_ buffer: CVPixelBuffer, crop: CGRect, session: Session) {
        session.lock.withLock {
            session.last = (buffer, crop)
            session.lastPush = .now()
        }
        session.video.push(buffer, crop: crop, timestampNs: Int64(DispatchTime.now().uptimeNanoseconds))
    }

    private func sendDisplays(_ session: Session) {
        let (sizes, current) = session.lock.withLock { (session.displays, session.current) }
        let message = ScreenHostMessage(t: "displays", displays: sizes.map { .init(w: Int($0.width), h: Int($0.height)) },
                                        current: current, name: pairing.name)
        if let data = try? JSONEncoder().encode(message) { _ = session.link.sendText(String(decoding: data, as: UTF8.self)) }
    }

    private func handleInput(_ data: Data, session: Session) {
        guard let input = try? JSONDecoder().decode(ScreenInput.self, from: data) else { return }
        if input.t == "display", let index = input.i {
            session.backend.select(display: index)
            return
        }
        if input.t == "quality", let quality = input.s.flatMap(ScreenQuality.init(rawValue:)) {
            session.lock.withLock { session.quality = quality }
            log("quality: \(quality.rawValue)")
            applyQuality(session)
            return
        }
        session.backend.handle(input)
    }

    private func applyQuality(_ session: Session) {
        let (quality, height) = session.lock.withLock { () -> (ScreenQuality, Int) in
            let size = session.displays.indices.contains(session.current) ? session.displays[session.current] : .zero
            return (session.quality, Int(size.height))
        }
        session.link.applyVideo(quality, sourceHeight: height)
    }

    private func endSession(ifCurrent expected: Session? = nil) {
        let ended = lock.withLock { () -> Session? in
            guard let session, expected == nil || session === expected else { return nil }
            self.session = nil
            return session
        }
        guard let ended else { return }
        for task in ended.tasks { task.cancel() }
        ended.backend.stop()
        ended.link.close()
        log("session ended")
        if ended.lock.withLock({ ended.opened }) { emit(.viewerEnded) }
    }
}

/// V1's frame source: this Mac's Screen Sharing over loopback (already
/// authorized), displays found from the image, input sent back as RFB.
public final class VNCLoopbackBackend: ScreenBackend, @unchecked Sendable {
    // @unchecked: state behind `lock`.
    private let client: VNCClient
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var displays: [CGRect] = []
    private var current = 0
    private var lastFrame: VNCFrame?
    private var onFrame: (@Sendable (CVPixelBuffer, CGRect) -> Void)?
    private var onDisplays: (@Sendable ([CGSize], Int) -> Void)?
    private var tasks: [Task<Void, Never>] = []

    private let inputStream: AsyncStream<ScreenInput>
    private let inputSink: AsyncStream<ScreenInput>.Continuation

    public init(target: VNCEndpoint, credentials: VNCCredentials, log: @escaping @Sendable (String) -> Void) {
        client = VNCClient(endpoint: target, options: VNCSessionOptions(credentials: credentials))
        self.log = log
        (inputStream, inputSink) = AsyncStream.makeStream(of: ScreenInput.self)
    }

    public func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void,
                      displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
        lock.withLock {
            onFrame = frame
            onDisplays = displays
        }
        let client = self.client
        let log = self.log
        let events = Task {
            await client.connect()
            for await event in client.events {
                if case let .disconnected(error) = event { log("Screen Sharing source ended: \(String(describing: error))") }
            }
        }
        let frames = Task { [weak self] in
            var lastDetection: UInt64 = 0
            for await frame in client.frames {
                guard let self else { return }
                if DispatchTime.now().uptimeNanoseconds - lastDetection > 1_000_000_000 {
                    lastDetection = DispatchTime.now().uptimeNanoseconds
                    detect(frame)
                }
                deliver(frame)
            }
        }
        let inputs = Task { [weak self, inputStream] in
            for await input in inputStream {
                guard let self else { return }
                await apply(input, client: client)
            }
        }
        lock.withLock { tasks = [events, frames, inputs] }
    }

    private func detect(_ frame: VNCFrame) {
        var found = VNCScreenLayout().screens(in: frame)
        if found.isEmpty { found = [CGRect(x: 0, y: 0, width: frame.width, height: frame.height)] }
        let changed = lock.withLock { () -> ([CGSize], Int, (@Sendable ([CGSize], Int) -> Void)?)? in
            guard found != displays else { return nil }
            if displays.isEmpty { current = found.firstIndex { $0.origin == .zero } ?? 0 }
            displays = found
            current = min(current, found.count - 1)
            return (found.map(\.size), current, onDisplays)
        }
        if let changed { changed.2?(changed.0, changed.1) }
    }

    private func deliver(_ frame: VNCFrame) {
        let (crop, sink) = lock.withLock { () -> (CGRect, (@Sendable (CVPixelBuffer, CGRect) -> Void)?) in
            lastFrame = frame
            let crop = displays.indices.contains(current) ? displays[current] : CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            return (crop, onFrame)
        }
        sink?(converter.nv12(frame.pixelBuffer) ?? frame.pixelBuffer, crop)
    }

    private let converter = NV12Converter()

    public func select(display index: Int) {
        let update = lock.withLock { () -> ([CGSize], Int, (@Sendable ([CGSize], Int) -> Void)?, VNCFrame?)? in
            guard displays.indices.contains(index) else { return nil }
            current = index
            return (displays.map(\.size), current, onDisplays, lastFrame)
        }
        guard let update else { return }
        update.2?(update.0, update.1)
        if let frame = update.3 { deliver(frame) }
    }

    /// Inputs go through one ordered queue, applied one at a time: a burst
    /// never reorders and never spawns a task per event.
    public func handle(_ input: ScreenInput) {
        inputSink.yield(input)
    }

    private func apply(_ input: ScreenInput, client: VNCClient) async {
        let display = lock.withLock { displays.indices.contains(current) ? displays[current] : .zero }
        let x = Int(display.minX + (input.x ?? 0) * display.width), y = Int(display.minY + (input.y ?? 0) * display.height)
        switch input.t {
        case "move": await client.pointer(x: x, y: y, buttons: VNCButtons(rawValue: input.b ?? 0))
        case "scroll":
            await client.movePointer(x: x, y: y)
            await client.scroll(dx: input.dx ?? 0, dy: input.dy ?? 0)
        case "key": if let keysym = input.k { await client.key(VNCKeysym(rawValue: keysym), down: input.d ?? true) }
        case "chord": if let keysym = input.k { await client.chord((input.m ?? []).map(VNCKeysym.init(rawValue:)), VNCKeysym(rawValue: keysym)) }
        case "text": if let text = input.s { await client.type(text) }
        case "refresh": await client.refresh()
        default: break
        }
    }

    public func stop() {
        let tasks = lock.withLock { self.tasks }
        for task in tasks { task.cancel() }
        let client = self.client
        Task { await client.disconnect() }
    }
}

/// The viewer side of a screen stream: signals through the room or the
/// host's tailnet port (`ScreenEndpoint`), receives the screen track, and
/// sends input. Callbacks arrive on arbitrary threads.
public final class ScreenStreamViewer: @unchecked Sendable {
    // @unchecked: mutable state is behind `lock`.
    public var onVideo: (@Sendable (VideoTrackBox) -> Void)?
    public var onDisplays: (@Sendable (ScreenHostMessage) -> Void)?
    public var onState: (@Sendable (String?) -> Void)?
    public var onPath: (@Sendable (String) -> Void)?

    public let endpoint: ScreenEndpoint
    /// The daemon's `tailnet.forward`, for a tailnet endpoint on `.daemonForward`.
    private let forwarding: (any TailnetForwarding)?
    private let lock = NSLock()
    private var link: VNCPeerLink?
    private var socket: (any SignalChannel)?
    private var tasks: [Task<Void, Never>] = []
    /// libwebrtc removes a track's renderers when its wrapper is released: keep it.
    private var track: VideoTrackBox?
    private var lastButtons: UInt8 = 0
    private var offered = false
    private var isOpen = false
    private var closed = false
    /// Tailnet: the ICE servers of the host's `ice` message, once it sends one.
    private var sessionICE: [ICEServerConfig]?
    /// TURN relay only (ICE transport policy `relay`): for checking the relay path. Off by default.
    private let relayOnly: Bool

    public convenience init(pairing: VNCPairing, relayOnly: Bool = false) {
        self.init(endpoint: .room(pairing), relayOnly: relayOnly)
    }

    public init(endpoint: ScreenEndpoint, forwarding: (any TailnetForwarding)? = nil, relayOnly: Bool = false) {
        self.endpoint = endpoint
        self.forwarding = forwarding
        self.relayOnly = relayOnly
    }

    /// Connects; returns when the input channel is open (video follows).
    /// Once open, only WebRTC ends the session (`onState`). Room: a dropped
    /// room connection is reopened quietly, and the Mac's room going away
    /// and coming back does not touch the running stream. Tailnet: one
    /// signaling link; the peer link is made when the host says hello, with
    /// the ICE servers of the host's `ice` message (sent before `hello`), else
    /// the fallback room's, else none.
    public func connect() async throws {
        let opened = OpenSignal()
        let signalTask: Task<Void, Never>
        switch endpoint {
        case let .room(pairing):
            _ = try makeLink(iceServers: try await SignalSocket.iceServers(pairing), opened: opened)
            // Weak between passes: a viewer that is released stops reconnecting.
            signalTask = Task { [weak self] in
                var delay = 1.0
                while !Task.isCancelled {
                    guard let pass = await self?.roomPass(pairing, opened: opened), pass.again else { return }
                    if pass.heard { delay = 1 }
                    try? await Task.sleep(for: .seconds(delay)) // room reconnect backoff
                    delay = min(delay * 2, 15)
                }
            }
        case let .tailnet(target):
            signalTask = Task { [weak self] in await self?.runTailnet(target, opened: opened) }
        }
        lock.withLock { tasks.append(signalTask) }
        do {
            try await opened.wait(timeout: 30)
        } catch {
            // A connect that failed leaves nothing behind: its room socket would
            // otherwise offer to the host when it next joins and open a session
            // nobody sees (the host shows a viewer that is not there).
            close()
            throw error
        }
    }

    /// The peer link with its event pump; closed at once when the viewer already is.
    private func makeLink(iceServers: [ICEServerConfig], opened: OpenSignal) throws -> VNCPeerLink {
        let link = try VNCPeerLink(iceServers: iceServers, relayOnly: relayOnly, preferStreamRelays: false)
        let peerTask = Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await self?.lock.withLock({ self?.socket })?.send(message)
                case .open:
                    self?.lock.withLock { self?.isOpen = true }
                    opened.fire(nil)
                case let .video(track):
                    self?.lock.withLock { self?.track = track }
                    self?.onVideo?(track)
                case let .message(data):
                    if let message = try? JSONDecoder().decode(ScreenHostMessage.self, from: data) { self?.onDisplays?(message) }
                case let .path(local, remote): self?.onPath?(local == "relay" || remote == "relay" ? "Relay" : "Direct")
                case .closed:
                    opened.fire(RFBError.connectionClosed)
                    // Before open, connect() reports the failure (it throws); reporting it here
                    // too would count one failed attempt as two drops.
                    if self?.lock.withLock({ self?.isOpen }) == true { self?.onState?("The connection closed.") }
                }
            }
        }
        let installed = lock.withLock { () -> Bool in
            guard !closed else { return false }
            self.link = link
            tasks.append(peerTask)
            return true
        }
        guard installed else {
            link.close()
            peerTask.cancel()
            throw RFBError.connectionClosed
        }
        return link
    }

    /// One room connection: returns whether to reconnect, and whether the
    /// room said anything (which resets the backoff).
    private func roomPass(_ pairing: VNCPairing, opened: OpenSignal) async -> (again: Bool, heard: Bool) {
        let socket = SignalSocket(pairing: pairing, role: "viewer")
        guard lock.withLock({ () -> Bool in
            guard !closed else { return false }
            self.socket = socket
            return true
        }) else { return (false, false) }
        var heard = false
        do {
            for try await message in socket.messages() {
                heard = true
                try await handleSignal(message, opened: opened)
            }
        } catch {
            guard lock.withLock({ isOpen }) else {
                opened.fire(RFBError.transport("signaling: \(error.localizedDescription)"))
                return (false, heard)
            }
        }
        socket.close()
        return (true, heard)
    }

    /// One tailnet signaling link. After the stream opens, the link closing
    /// does not end the stream (WebRTC does, through `onState`).
    private func runTailnet(_ target: TailnetScreenTarget, opened: OpenSignal) async {
        let socket: TailnetSignalSocket
        switch target.route {
        case .systemTailscale:
            socket = TailnetSignalSocket(host: target.host, port: target.port)
        case .daemonForward:
            guard let forwarding else {
                opened.fire(TailnetSignalError.noForwarding)
                return
            }
            do {
                socket = TailnetSignalSocket(local: try await forwarding.forward(target: target.forwardTarget))
            } catch {
                opened.fire(TailnetSignalError.forwardFailed(String(describing: error)))
                return
            }
        }
        guard lock.withLock({ () -> Bool in
            guard !closed else { return false }
            self.socket = socket
            return true
        }) else {
            socket.close()
            return
        }
        do {
            for try await message in socket.messages() {
                try await handleSignal(message, opened: opened)
            }
            if !lock.withLock({ isOpen }) { opened.fire(TailnetSignalError.closed) }
        } catch {
            if !lock.withLock({ isOpen }) {
                opened.fire(error as? TailnetSignalError ?? TailnetSignalError.unreachable(String(describing: error)))
            }
        }
        socket.close()
    }

    /// The running link, or a new one for a tailnet host that just said hello.
    private func currentOrNewLink(opened: OpenSignal) async throws -> VNCPeerLink {
        if let link = lock.withLock({ link }) { return link }
        var servers = lock.withLock { sessionICE }
        if servers == nil, case let .tailnet(target) = endpoint, let room = target.fallbackRoom {
            // The room is only a source of ICE servers here; without them the
            // tailnet path still has host candidates.
            servers = try? await SignalSocket.iceServers(room)
        }
        return try makeLink(iceServers: servers ?? [], opened: opened)
    }

    private func handleSignal(_ message: SignalMessage, opened: OpenSignal) async throws {
        switch message.type {
        case "hello" where message.peer == true, "peer-joined":
            // One offer per session; the host's room reconnecting is not a new viewer.
            guard lock.withLock({ () -> Bool in
                defer { offered = true }
                return !offered
            }) else { return }
            let link = try await currentOrNewLink(opened: opened)
            let sdp = try await link.offer(label: "input", receiveVideo: true, unorderedLabel: "pointer")
            try await lock.withLock({ socket })?.send(SignalMessage(type: "offer", sdp: sdp))
        case "ice":
            // Tailnet only: the room's ICE servers come from the Worker, not from a peer.
            guard case .tailnet = endpoint, let servers = message.iceServers else { return }
            let link = lock.withLock { () -> VNCPeerLink? in
                sessionICE = servers
                return self.link
            }
            // Sent after the offer: the next gathering uses them.
            link?.useICEServers(servers)
        case "answer":
            if let sdp = message.sdp, let link = lock.withLock({ link }) { try await link.accept(answer: sdp) }
        case "candidate":
            if let link = lock.withLock({ link }) { await link.add(candidate: message) }
        case "peer-left":
            guard !lock.withLock({ isOpen }) else { return }
            opened.fire(RFBError.transport("the Mac's host left"))
            lock.withLock({ link })?.close()
        default:
            break
        }
    }

    /// Asks the Mac for `quality` (sent again by the app after a reconnect).
    public func setQuality(_ quality: ScreenQuality) {
        send(ScreenInput(t: "quality", s: quality.rawValue))
    }

    /// Sends input: pointer moves with no button change on the unordered
    /// `pointer` channel (latest wins), everything else on the ordered one.
    public func send(_ input: ScreenInput) {
        guard let link = lock.withLock({ link }), let data = try? JSONEncoder().encode(input) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let pointerOnly = input.t == "move" && lock.withLock { () -> Bool in
            defer { lastButtons = input.b ?? 0 }
            return (input.b ?? 0) == lastButtons
        }
        if pointerOnly, link.sendText(text, on: "pointer") { return }
        _ = link.sendText(text)
    }

    /// Live video numbers from WebRTC: decoded fps, receive rate, RTT, path.
    public struct VideoStats: Sendable {
        public var fps: Double?
        public var kilobytesPerSecond: Double?
        public var rttMs: Double?
        public var jitterBufferMs: Double?
        public var codec: String?
        /// libwebrtc's decoder (VideoToolbox is hardware).
        public var decoder: String?
        public var bytesReceived: Double = 0
        public var framesDecoded: Double = 0
    }

    public func videoStats() async -> VideoStats {
        guard let link = lock.withLock({ link }) else { return VideoStats() }
        return await link.videoStats()
    }

    public func close() {
        let (link, socket, tasks) = lock.withLock { () -> (VNCPeerLink?, (any SignalChannel)?, [Task<Void, Never>]) in
            closed = true
            defer { self.tasks.removeAll() }
            return (self.link, self.socket, self.tasks)
        }
        link?.close()
        socket?.close()
        for task in tasks { task.cancel() }
    }
}

/// BGRA → NV12 on the GPU (VTPixelTransferSession). The hardware H.264
/// encoder takes NV12; without this libwebrtc converts on the CPU and its
/// overuse detector lowers the frame rate ("limited-by cpu").
final class NV12Converter: @unchecked Sendable {
    // @unchecked: used from one frame task.
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var size = (0, 0)

    func nv12(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if session == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
        if pool == nil || size != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attributes as CFDictionary, &pool)
            size = (width, height)
        }
        guard let session, let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output, VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else { return nil }
        return output
    }
}
