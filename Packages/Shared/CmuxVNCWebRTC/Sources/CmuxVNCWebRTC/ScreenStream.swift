import CmuxVNC
import CoreGraphics
import CoreVideo
import Foundation
import Network

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
        init(link: VNCPeerLink, backend: any ScreenBackend) {
            self.link = link
            self.backend = backend
        }
    }

    public let pairing: VNCPairing
    private let makeBackend: @Sendable () -> any ScreenBackend
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var session: Session?

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
            }
            try? await Task.sleep(for: .seconds(delay)) // reconnect backoff
            delay = min(delay * 2, 30)
        }
    }

    private func serveRoom() async throws {
        let socket = SignalSocket(pairing: pairing, role: "host")
        defer { socket.close() }
        for try await message in socket.messages() {
            switch message.type {
            case "hello": log("waiting for a viewer in room \(pairing.room.prefix(8))…")
            case "offer":
                guard let sdp = message.sdp else { continue }
                try await accept(offer: sdp, socket: socket)
            case "candidate": await lock.withLock({ session?.link })?.add(candidate: message)
            case "peer-left":
                log("viewer left")
                endSession()
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
        log("channel open; starting \(type(of: session.backend))")
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
                })
            } catch {
                self?.log("screen source failed: \(error)")
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
        session.backend.handle(input)
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

    public init(target: VNCEndpoint, credentials: VNCCredentials, log: @escaping @Sendable (String) -> Void) {
        client = VNCClient(endpoint: target, options: VNCSessionOptions(credentials: credentials))
        self.log = log
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
        lock.withLock { tasks = [events, frames] }
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
        sink?(frame.pixelBuffer, crop)
    }

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

    public func handle(_ input: ScreenInput) {
        let display = lock.withLock { displays.indices.contains(current) ? displays[current] : .zero }
        let client = self.client
        let x = Int(display.minX + (input.x ?? 0) * display.width), y = Int(display.minY + (input.y ?? 0) * display.height)
        Task {
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
    }

    public func stop() {
        let tasks = lock.withLock { self.tasks }
        for task in tasks { task.cancel() }
        let client = self.client
        Task { await client.disconnect() }
    }
}

/// The phone side of a screen stream: joins the room, receives the screen
/// track, and sends input. Callbacks arrive on arbitrary threads.
public final class ScreenStreamViewer: @unchecked Sendable {
    // @unchecked: mutable state is behind `lock`.
    public var onVideo: (@Sendable (VideoTrackBox) -> Void)?
    public var onDisplays: (@Sendable (ScreenHostMessage) -> Void)?
    public var onState: (@Sendable (String?) -> Void)?
    public var onPath: (@Sendable (String) -> Void)?

    private let pairing: VNCPairing
    private let lock = NSLock()
    private var link: VNCPeerLink?
    private var socket: SignalSocket?
    private var tasks: [Task<Void, Never>] = []
    /// libwebrtc removes a track's renderers when its wrapper is released: keep it.
    private var track: VideoTrackBox?
    private var lastButtons: UInt8 = 0

    public init(pairing: VNCPairing) {
        self.pairing = pairing
    }

    /// Connects; returns when the input channel is open (video follows).
    public func connect() async throws {
        let ice = try await SignalSocket.iceServers(pairing)
        let socket = SignalSocket(pairing: pairing, role: "viewer")
        let link = try VNCPeerLink(iceServers: ice, preferStreamRelays: false)
        lock.withLock {
            self.link = link
            self.socket = socket
        }
        let opened = OpenSignal()
        let peerTask = Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await socket.send(message)
                case .open: opened.fire(nil)
                case let .video(track):
                    self?.lock.withLock { self?.track = track }
                    self?.onVideo?(track)
                case let .message(data):
                    if let message = try? JSONDecoder().decode(ScreenHostMessage.self, from: data) { self?.onDisplays?(message) }
                case let .path(local, remote): self?.onPath?(local == "relay" || remote == "relay" ? "Relay" : "Direct")
                case .closed:
                    opened.fire(RFBError.connectionClosed)
                    self?.onState?("The connection closed.")
                }
            }
        }
        let signalTask = Task {
            do {
                for try await message in socket.messages() {
                    switch message.type {
                    case "hello" where message.peer == true, "peer-joined":
                        let sdp = try await link.offer(label: "input", receiveVideo: true, unorderedLabel: "pointer")
                        try await socket.send(SignalMessage(type: "offer", sdp: sdp))
                    case "answer":
                        if let sdp = message.sdp { try await link.accept(answer: sdp) }
                    case "candidate":
                        await link.add(candidate: message)
                    case "peer-left":
                        opened.fire(RFBError.transport("the Mac's host left"))
                        link.close()
                    default:
                        break
                    }
                }
            } catch {
                opened.fire(RFBError.transport("signaling: \(error.localizedDescription)"))
            }
        }
        lock.withLock { tasks = [peerTask, signalTask] }
        try await opened.wait(timeout: 30)
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
        let (link, socket, tasks) = lock.withLock { () -> (VNCPeerLink?, SignalSocket?, [Task<Void, Never>]) in
            defer { self.tasks.removeAll() }
            return (self.link, self.socket, self.tasks)
        }
        link?.close()
        socket?.close()
        for task in tasks { task.cancel() }
    }
}
