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

/// The Mac side of a screen stream. Frames come from this Mac's own Screen
/// Sharing over loopback (already authorized, no Screen Recording grant
/// needed); each viewer gets one display, cropped, as a WebRTC video track
/// (hardware H.264), and its input goes back to Screen Sharing. A frame
/// source with ScreenCaptureKit can replace the loopback one later.
public final class ScreenStreamHost: @unchecked Sendable {
    // @unchecked: `session` is behind `lock`.
    private final class Session: @unchecked Sendable {
        let link: VNCPeerLink
        let video = ScreenVideoSource()
        var client: VNCClient?
        var displays: [CGRect] = []
        var current = 0
        var tasks: [Task<Void, Never>] = []
        var lastFrame: VNCFrame?
        var lastPush = DispatchTime.now()
        var pointer = CGPoint.zero
        var buttons: UInt8 = 0
        init(link: VNCPeerLink) { self.link = link }
    }

    public let pairing: VNCPairing
    private let target: VNCEndpoint
    private let credentials: VNCCredentials
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var session: Session?

    public init(pairing: VNCPairing, target: VNCEndpoint, credentials: VNCCredentials, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.pairing = pairing
        self.target = target
        self.credentials = credentials
        self.log = log
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
        let link = try VNCPeerLink(iceServers: try await SignalSocket.iceServers(pairing))
        let session = Session(link: link)
        lock.withLock { self.session = session }
        session.tasks.append(Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await socket.send(message)
                case .open: self?.startFrames(session)
                case let .message(data): self?.handleInput(data, session: session)
                case .closed: self?.endSession(ifCurrent: session)
                case let .path(local, remote):
                    self?.log("path: this Mac \(local) ↔ viewer \(remote)\(local == "relay" || remote == "relay" ? " (TURN relay)" : " (direct)")")
                case .video: break
                }
            }
        })
        let answer = try await link.answer(offer: sdp, video: session.video)
        if ProcessInfo.processInfo.environment["CMUX_VNC_SDP_DEBUG"] != nil {
            for (label, text) in [("offer", sdp), ("answer", answer)] {
                for line in text.components(separatedBy: "\r\n") where line.hasPrefix("m=video") || (line.hasPrefix("a=rtpmap") && !line.contains("rtx") ) {
                    log("sdp \(label): \(line)")
                }
            }
        }
        try await socket.send(SignalMessage(type: "answer", sdp: answer))
        log("viewer offered; streaming answer sent")
    }

    // MARK: Frames

    private func startFrames(_ session: Session) {
        let client = VNCClient(endpoint: target, options: VNCSessionOptions(credentials: credentials))
        session.client = client
        log("channel open; reading \(target.label)")
        session.tasks.append(Task { [weak self] in
            await client.connect()
            for await event in client.events {
                if case let .disconnected(error) = event { self?.log("screen source ended: \(String(describing: error))") }
            }
        })
        session.tasks.append(Task { [weak self] in
            var lastDetection = DispatchTime(uptimeNanoseconds: 0)
            for await frame in client.frames {
                guard let self else { return }
                if DispatchTime.now().uptimeNanoseconds - lastDetection.uptimeNanoseconds > 1_000_000_000 {
                    lastDetection = .now()
                    updateDisplays(session, frame: frame)
                }
                push(frame, session: session)
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
        // Idle refresh: a static screen still answers keyframe requests and sharpens.
        session.tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500)) // idle refresh period
                guard let self, let frame = session.lastFrame else { continue }
                if DispatchTime.now().uptimeNanoseconds - session.lastPush.uptimeNanoseconds > 450_000_000 { push(frame, session: session) }
            }
        })
    }

    private func updateDisplays(_ session: Session, frame: VNCFrame) {
        var displays = VNCScreenLayout().screens(in: frame)
        if displays.isEmpty { displays = [CGRect(x: 0, y: 0, width: frame.width, height: frame.height)] }
        guard displays != session.displays else { return }
        let first = session.displays.isEmpty
        session.displays = displays
        if first { session.current = displays.firstIndex { $0.origin == .zero } ?? 0 }
        session.current = min(session.current, displays.count - 1)
        sendDisplays(session)
    }

    private func sendDisplays(_ session: Session) {
        let message = ScreenHostMessage(t: "displays", displays: session.displays.map { .init(w: Int($0.width), h: Int($0.height)) },
                                        current: session.current, name: pairing.name)
        if let data = try? JSONEncoder().encode(message) { _ = session.link.sendText(String(decoding: data, as: UTF8.self)) }
    }

    private func push(_ frame: VNCFrame, session: Session) {
        session.lastFrame = frame
        session.lastPush = .now()
        let crop = session.displays.indices.contains(session.current) ? session.displays[session.current]
            : CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        session.video.push(frame.pixelBuffer, crop: crop, timestampNs: Int64(DispatchTime.now().uptimeNanoseconds))
    }

    // MARK: Input

    private func handleInput(_ data: Data, session: Session) {
        guard let input = try? JSONDecoder().decode(ScreenInput.self, from: data), let client = session.client else { return }
        let display = session.displays.indices.contains(session.current) ? session.displays[session.current] : .zero
        func point() -> (Int, Int) {
            (Int(display.minX + (input.x ?? 0) * display.width), Int(display.minY + (input.y ?? 0) * display.height))
        }
        Task {
            switch input.t {
            case "move":
                let (x, y) = point()
                await client.pointer(x: x, y: y, buttons: VNCButtons(rawValue: input.b ?? 0))
            case "scroll":
                let (x, y) = point()
                await client.movePointer(x: x, y: y)
                await client.scroll(dx: input.dx ?? 0, dy: input.dy ?? 0)
            case "key":
                if let keysym = input.k { await client.key(VNCKeysym(rawValue: keysym), down: input.d ?? true) }
            case "chord":
                if let keysym = input.k { await client.chord((input.m ?? []).map(VNCKeysym.init(rawValue:)), VNCKeysym(rawValue: keysym)) }
            case "text":
                if let text = input.s { await client.type(text) }
            case "display":
                if let index = input.i, session.displays.indices.contains(index) {
                    session.current = index
                    sendDisplays(session)
                    if let frame = session.lastFrame { push(frame, session: session) }
                }
            case "refresh":
                await client.refresh()
            default:
                break
            }
        }
    }

    private func endSession(ifCurrent expected: Session? = nil) {
        let ended = lock.withLock { () -> Session? in
            guard let session, expected == nil || session === expected else { return nil }
            self.session = nil
            return session
        }
        guard let ended else { return }
        for task in ended.tasks { task.cancel() }
        if let client = ended.client { Task { await client.disconnect() } }
        ended.link.close()
        log("session ended")
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

    public init(pairing: VNCPairing) {
        self.pairing = pairing
    }

    /// Connects; returns when the input channel is open (video follows).
    public func connect() async throws {
        let ice = try await SignalSocket.iceServers(pairing)
        let socket = SignalSocket(pairing: pairing, role: "viewer")
        let link = try VNCPeerLink(iceServers: ice)
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
                        let sdp = try await link.offer(label: "input", receiveVideo: true)
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

    public func send(_ input: ScreenInput) {
        guard let link = lock.withLock({ link }), let data = try? JSONEncoder().encode(input) else { return }
        _ = link.sendText(String(decoding: data, as: UTF8.self))
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
