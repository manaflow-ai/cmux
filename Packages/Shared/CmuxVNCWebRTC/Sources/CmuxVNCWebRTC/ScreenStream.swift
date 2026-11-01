import CmuxVNC
import CoreGraphics
import CoreVideo
import Foundation
import Network
import VideoToolbox
import WebRTC

/// Viewer → host input and control on the `input` data channel. Pointer
/// coordinates are normalized (0...1) within the display being streamed.
/// `fps` (with `i`) is the most frames per second the viewer's display
/// shows; a host that predates it ignores it and streams at 60.
public struct ScreenInput: Codable, Sendable {
    /// move, scroll, key, chord, text, display, refresh, quality, fps
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
    /// The unit of a `scroll`'s `dx`/`dy`: nil for lines (every host), or
    /// ``pixelUnit`` for pixels, sent only to a host whose `caps` message
    /// listed ``ScreenHostMessage/pixelScrollCapability``.
    public var u: String?

    /// `u` for a scroll in pixels. Send whole pixels and carry the leftover
    /// fraction into the next scroll: a fraction rounds to the nearest pixel,
    /// so many small deltas sent as they come would round to nothing.
    public static let pixelUnit = "px"

    public init(t: String, x: Double? = nil, y: Double? = nil, b: UInt8? = nil, dx: Int? = nil, dy: Int? = nil,
                k: UInt32? = nil, d: Bool? = nil, s: String? = nil, i: Int? = nil, m: [UInt32]? = nil, u: String? = nil) {
        self.t = t; self.x = x; self.y = y; self.b = b; self.dx = dx; self.dy = dy
        self.k = k; self.d = d; self.s = s; self.i = i; self.m = m; self.u = u
    }

    /// As the synthesized decoding, except that a fractional `dx`/`dy` (a
    /// pixel scroll) rounds to the nearest whole value instead of failing
    /// the whole message.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func delta(_ key: CodingKeys) throws -> Int? {
            if let whole = try? container.decodeIfPresent(Int.self, forKey: key) { return whole }
            guard let value = try container.decodeIfPresent(Double.self, forKey: key) else { return nil }
            guard value.isFinite else { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not a finite delta") }
            return Int(clamping: Int64(max(min(value.rounded(), 1e15), -1e15)))
        }
        t = try container.decode(String.self, forKey: .t)
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        b = try container.decodeIfPresent(UInt8.self, forKey: .b)
        dx = try delta(.dx)
        dy = try delta(.dy)
        k = try container.decodeIfPresent(UInt32.self, forKey: .k)
        d = try container.decodeIfPresent(Bool.self, forKey: .d)
        s = try container.decodeIfPresent(String.self, forKey: .s)
        i = try container.decodeIfPresent(Int.self, forKey: .i)
        m = try container.decodeIfPresent([UInt32].self, forKey: .m)
        u = try container.decodeIfPresent(String.self, forKey: .u)
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

    /// The rate a stream runs at unless both displays can show more, and the
    /// least Auto and Smooth Motion ask for.
    static let baselineFrameRate = 60
    /// The most a stream asks for (ProMotion).
    static let maximumFrameRate = 120
    /// Auto and Smooth Motion's bitrate ceiling at 60 fps: 200 kbit a frame.
    static let adaptiveBitrateAtBaseline = 12_000_000
    /// The most pixels a second Auto and Smooth Motion ask the hardware
    /// H.264 encoder for above 60 fps (2160×1396 at 120). VideoToolbox's
    /// H.264 encoder is bound by pixels a second, not by its level or
    /// settings: an M1 Max sustains about 400 Mpixel/s (3456×2234 at 55 fps,
    /// 2160×1396 at 120 with 28 ms latency), an M4 Pro about 500. One value
    /// for every Mac (not measured per chip): ProMotion Macs are M1 Pro or later.
    static let maximumEncodedPixelRate = 360_000_000

    /// The frames per second to capture and encode at. Auto and Smooth
    /// Motion follow both screens: the lower of the most the host's captured
    /// display and the viewer's display show, at most 120 and never below
    /// 60. A rate nobody reported (an older peer, a source that does not
    /// know it, a display that says 0) counts as 60, so the stream stays
    /// where it was. The fixed presets keep their own rate.
    func frameRate(hostMaximum: Int?, viewerMaximum: Int?) -> Int {
        switch self {
        case .low, .medium, .high:
            return settings(sourceHeight: 0).maxFramerate
        case .auto, .smooth:
            let known = { (rate: Int?) -> Int in rate.flatMap { $0 > 0 ? $0 : nil } ?? Self.baselineFrameRate }
            return min(max(min(known(hostMaximum), known(viewerMaximum)), Self.baselineFrameRate), Self.maximumFrameRate)
        }
    }

    /// The sender's encoding for a display `sourceWidth`×`sourceHeight`
    /// pixels (0: unknown) at `frameRate` (from
    /// ``frameRate(hostMaximum:viewerMaximum:)``).
    /// Auto and Smooth Motion's bitrate ceiling grows with the frame rate so
    /// each frame keeps its 200 kbit (24 Mbps at 120): at a fixed ceiling
    /// every frame would get half the bits and text would blur in motion.
    /// It is a ceiling, not a target: WebRTC's congestion control still sets
    /// the rate from the network, and a still screen sends next to nothing.
    /// Above 60 fps they also scale the picture down just enough to stay
    /// within ``maximumEncodedPixelRate``: a 16" MacBook Pro's 3456×2234 goes
    /// out at about 2154×1392 at 120 fps (60 fps keeps the full size).
    func settings(sourceWidth: Int = 0, sourceHeight: Int, frameRate: Int = ScreenQuality.baselineFrameRate) -> Settings {
        func scale(to height: Int) -> Double { sourceHeight > height ? Double(sourceHeight) / Double(height) : 1 }
        let fps = min(max(frameRate, Self.baselineFrameRate), Self.maximumFrameRate)
        let adaptiveBitrate = Self.adaptiveBitrateAtBaseline / Self.baselineFrameRate * fps
        let pixelRate = Double(sourceWidth) * Double(sourceHeight) * Double(fps)
        let fitEncoder = fps > Self.baselineFrameRate && pixelRate > Double(Self.maximumEncodedPixelRate)
            ? (pixelRate / Double(Self.maximumEncodedPixelRate)).squareRoot() : 1
        switch self {
        case .auto: return Settings(degradation: .maintainResolution, maxBitrate: adaptiveBitrate, maxFramerate: fps, scaleDown: fitEncoder)
        case .smooth: return Settings(degradation: .maintainFramerate, maxBitrate: adaptiveBitrate, maxFramerate: fps, scaleDown: fitEncoder)
        case .low: return Settings(degradation: .disabled, maxBitrate: 1_500_000, minBitrate: 1_500_000, maxFramerate: 30, scaleDown: scale(to: 720))
        case .medium: return Settings(degradation: .disabled, maxBitrate: 4_000_000, minBitrate: 4_000_000, maxFramerate: 30, scaleDown: scale(to: 1080))
        case .high: return Settings(degradation: .disabled, maxBitrate: 10_000_000, minBitrate: 10_000_000, maxFramerate: 60, scaleDown: 1)
        }
    }
}

/// Host → viewer: the displays and which one is streaming, and the frame
/// rate the host streams at (`fps`; an older host sends none, an older
/// viewer ignores it).
public struct ScreenHostMessage: Codable, Sendable {
    public struct Display: Codable, Sendable, Equatable {
        public var w: Int
        public var h: Int
    }

    public var t: String
    public var displays: [Display]?
    public var current: Int?
    public var name: String?
    /// The frames per second the stream is set to (the agreed rate, not the measured one).
    public var fps: Int?
    /// For `caps`: the input this host understands beyond the first
    /// protocol, as a comma list (``pixelScrollCapability``,
    /// ``modifiedPointerCapability``). An older host sends no `caps`.
    public var s: String?

    /// `t` of the message a host sends once its input channel opens.
    public static let capabilitiesType = "caps"
    /// The host posts `scroll` with `u: "px"` as pixel (continuous) scrolling.
    public static let pixelScrollCapability = "scroll-px"
    /// Pointer events carry the modifier keys held down (a modifier `key` down, then a click, is a modified click).
    public static let modifiedPointerCapability = "mods"
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
    /// What the host tells the viewer it understands in `caps`
    /// (``ScreenHostMessage/pixelScrollCapability``, ...); none by default.
    var inputCapabilities: [String] { get }
    /// The most frames per second the streaming display shows (ProMotion:
    /// 120); nil when the source does not know. Read again whenever the
    /// source reports its displays.
    var maximumFrameRate: Int? { get }
    /// Captures at most `fps` frames per second from now on.
    func setFrameRate(_ fps: Int)
}

/// Sources that do not know their display's rate (the Screen Sharing
/// loopback) report none and keep their own pace: the stream stays at 60.
public extension ScreenBackend {
    var maximumFrameRate: Int? { nil }
    var inputCapabilities: [String] { [] }
    func setFrameRate(_ fps: Int) {}
}

/// The Mac side of a screen stream: answers a viewer with the screen as a
/// WebRTC video track (hardware H.264) and hands the viewer's input to the
/// backend. One viewer at a time. Signaling is a pairing link's room
/// (``run()``, held open and reopened) or one device hub session
/// (``serve(_:)`` with a ``TicketSignaling``). A view-only host (a device
/// hub `view` session) never passes input to the backend.
// crash-allow: `session` is read and written only under `lock`.
public final class ScreenStreamHost: @unchecked Sendable {
    // @unchecked: `session` is behind `lock`; a session's fields are touched
    // from its own tasks and the backend's callback queue.
    // crash-allow: a session's mutable fields are read and written under its own `lock`.
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
        /// The most frames per second the viewer's display shows (nil: not reported, an older viewer).
        var viewerFrameRate: Int?
        /// The rate the stream is set to (nil until the source reports its displays).
        var frameRate: Int?
        /// Pictures the source delivered since the last encoder log line (idle refreshes not counted).
        var captured = 0
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

    /// The room ``run()`` holds open; nil for a host that serves device hub sessions.
    public let pairing: VNCPairing?
    /// The name the viewer shows for this Mac.
    public let name: String
    /// A `view` scope session: input from the viewer is ignored (only the display choice and refresh pass).
    public let viewOnly: Bool
    private let makeBackend: @Sendable () -> any ScreenBackend
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var session: Session?
    /// The device hub session ``serve(_:)`` is serving, for `bye` on disconnect.
    private var ticketSignaling: (any ScreenSignaling)?
    /// Called from the host's tasks with each `Event` (any thread).
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.withLock { eventSink } }
        set { lock.withLock { eventSink = newValue } }
    }
    private var eventSink: (@Sendable (Event) -> Void)?

    public init(pairing: VNCPairing, viewOnly: Bool = false, backend: @escaping @Sendable () -> any ScreenBackend,
                log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.pairing = pairing
        name = pairing.name
        self.viewOnly = viewOnly
        makeBackend = backend
        self.log = log
    }

    /// A host for device hub sessions (``serve(_:)``); no room.
    public init(name: String, viewOnly: Bool = false, backend: @escaping @Sendable () -> any ScreenBackend,
                log: @escaping @Sendable (String) -> Void = { print($0) }) {
        pairing = nil
        self.name = name
        self.viewOnly = viewOnly
        makeBackend = backend
        self.log = log
    }

    /// The loopback Screen Sharing backend (V1).
    public convenience init(pairing: VNCPairing, target: VNCEndpoint, credentials: VNCCredentials,
                            log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.init(pairing: pairing, backend: { VNCLoopbackBackend(target: target, credentials: credentials, log: log) }, log: log)
    }

    /// Holds the pairing room open until cancelled (nothing to do without a pairing).
    public func run() async {
        guard let pairing else { return }
        var delay = 1.0
        while !Task.isCancelled {
            do {
                try await serve(RoomSignaling(pairing: pairing, role: "host"))
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

    /// Ends the current viewer's session (it may connect again with the link;
    /// a device hub session gets `bye` and ends for good).
    public func disconnectViewer() {
        endSession()
        guard let signaling = lock.withLock({ ticketSignaling }) else { return }
        Task {
            try? await signaling.send(.bye)
            signaling.close()
        }
    }

    private func emit(_ event: Event) {
        lock.withLock { eventSink }?(event)
    }

    /// Serves one signaling connection until it closes. A session that is
    /// its signaling (``ScreenSignaling/endsSessionOnClose``, a device hub
    /// ticket) ends with it: on `bye`, on a close, and on an error such as a
    /// fingerprint that does not verify.
    public func serve(_ signaling: any ScreenSignaling) async throws {
        if signaling.endsSessionOnClose { lock.withLock { ticketSignaling = signaling } }
        defer {
            signaling.close()
            if signaling.endsSessionOnClose {
                lock.withLock { if ticketSignaling === signaling { ticketSignaling = nil } }
                // A session whose channel opened lives on without its signaling
                // (a dropped hub link): WebRTC, `bye` or `disconnectViewer()` ends it.
                let current = lock.withLock { session }
                if !(current.map { session in session.lock.withLock { session.opened } } ?? false) { endSession() }
            }
        }
        for try await signal in signaling.messages() {
            switch signal {
            case .hello:
                log(pairing.map { "waiting for a viewer in room \($0.room.prefix(8))…" } ?? "waiting for the viewer…")
                emit(.waiting)
            case let .offer(sdp):
                try await accept(offer: sdp, signaling: signaling)
            case let .candidate(candidate): await lock.withLock({ session?.link })?.add(candidate: candidate.message)
            case .bye:
                log("the session ended")
                endSession()
                return
            case .peerJoined, .answer, .path: break
            case .peerLeft:
                // The viewer's room connection dropped. A connected session
                // lives on (WebRTC reports its own end); a half-open one ends.
                let current = lock.withLock { session }
                if let current, current.lock.withLock({ current.opened }) {
                    log("viewer's room connection dropped; the stream continues")
                } else {
                    log("viewer left")
                    endSession()
                }
            }
        }
    }

    private func accept(offer sdp: String, signaling: any ScreenSignaling) async throws {
        endSession()
        let link = try VNCPeerLink(iceServers: try await signaling.iceServers(), preferStreamRelays: false)
        let session = Session(link: link, backend: makeBackend())
        lock.withLock { self.session = session }
        session.tasks.append(Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await signaling.send(.candidate(ScreenICECandidate(message)))
                case .open: self?.start(session)
                case let .message(data): self?.handleInput(data, session: session)
                case .closed:
                    self?.endSession(ifCurrent: session)
                    // A device hub session is this connection: tell the other side, then let it go.
                    if signaling.endsSessionOnClose {
                        try? await signaling.send(.bye)
                        signaling.close()
                    }
                case let .path(local, remote):
                    self?.log("path: this Mac \(local) ↔ viewer \(remote)\(local == "relay" || remote == "relay" ? " (TURN relay)" : " (direct)")")
                case .video: break
                }
            }
        })
        let answer = try await link.answer(offer: sdp, video: session.video)
        try await signaling.send(.answer(answer))
        log("viewer offered; streaming answer sent")
    }

    private func start(_ session: Session) {
        session.lock.withLock { session.opened = true }
        log("channel open; starting \(type(of: session.backend))")
        emit(.viewerConnected)
        sendCapabilities(session)
        session.tasks.append(Task { [weak self] in
            do {
                try await session.backend.start(frame: { [weak self] buffer, crop in
                    session.lock.withLock { session.captured += 1 }
                    self?.push(buffer, crop: crop, session: session)
                }, displays: { [weak self] sizes, current in
                    session.lock.withLock {
                        session.displays = sizes
                        session.current = current
                    }
                    // Another display may refresh at another rate: the rate first, then the message that carries it.
                    self?.applyQuality(session)
                    self?.sendDisplays(session)
                })
            } catch {
                self?.log("screen source failed: \(error)")
                self?.emit(.sourceFailed("\(error)"))
            }
        })
        // Every 3 s: what the encoder is doing (codec, hardware, fps, limits),
        // how many pictures the source delivered, and the rate the stream is set to.
        session.tasks.append(Task { [weak self] in
            var since = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3)) // sampling period
                guard let self else { return }
                let summary = await session.link.outboundVideoSummary()
                let now = DispatchTime.now().uptimeNanoseconds
                let (captured, target) = session.lock.withLock { () -> (Int, Int?) in
                    defer { session.captured = 0 }
                    return (session.captured, session.frameRate)
                }
                let seconds = max(Double(now - since) / 1e9, 0.001)
                since = now
                log("video: \(summary) capture \(String(format: "%.1f", Double(captured) / seconds)) fps target \(target.map(String.init) ?? "-") fps")
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
        let (sizes, current, fps) = session.lock.withLock { (session.displays, session.current, session.frameRate) }
        // Before the source reports its displays there is nothing to say (the displays callback sends it).
        guard !sizes.isEmpty else { return }
        let message = ScreenHostMessage(t: "displays", displays: sizes.map { .init(w: Int($0.width), h: Int($0.height)) },
                                        current: current, name: name, fps: fps)
        if let data = try? JSONEncoder().encode(message) { _ = session.link.sendText(String(decoding: data, as: UTF8.self)) }
    }

    /// The viewer's display rate from its `fps` report; nil for any other
    /// message or a rate no display has.
    static func reportedFrameRate(_ input: ScreenInput) -> Int? {
        guard input.t == ScreenStreamViewer.frameRateMessage, let fps = input.i, (1 ... 1000).contains(fps) else { return nil }
        return fps
    }

    /// Whether a viewer message ends its session (the viewer left: `bye`).
    static func endsSession(_ input: ScreenInput) -> Bool { input.t == "bye" }

    private func handleInput(_ data: Data, session: Session) {
        guard let input = try? JSONDecoder().decode(ScreenInput.self, from: data) else { return }
        if Self.endsSession(input) {
            // The viewer left (closed its tab, disconnected): end now, view-only sessions too.
            log("the viewer left")
            endSession(ifCurrent: session)
            return
        }
        if input.t == "quality", let quality = input.s.flatMap(ScreenQuality.init(rawValue:)) {
            session.lock.withLock { session.quality = quality }
            log("quality: \(quality.rawValue)")
            if applyQuality(session) { sendDisplays(session) }
            return
        }
        if input.t == ScreenStreamViewer.frameRateMessage {
            // The viewer's display, not input: view-only sessions too.
            guard let fps = Self.reportedFrameRate(input) else { return }
            session.lock.withLock { session.viewerFrameRate = fps }
            log("viewer display: \(fps) Hz")
            if applyQuality(session) { sendDisplays(session) }
            return
        }
        deliver(input, to: session.backend)
    }

    /// Hands one viewer message to the backend: the display choice always,
    /// input only when the session is not view-only.
    func deliver(_ input: ScreenInput, to backend: any ScreenBackend) {
        if input.t == "display" {
            if let index = input.i { backend.select(display: index) }
            return
        }
        guard !viewOnly || Self.viewOnlyMessages.contains(input.t) else { return }
        // A scroll in a unit the backend did not advertise never reaches it (40 px is not 40 lines).
        if input.t == "scroll", let unit = input.u,
           unit != ScreenInput.pixelUnit || !backend.inputCapabilities.contains(ScreenHostMessage.pixelScrollCapability) { return }
        backend.handle(input)
    }

    /// What a view-only viewer may still send: a request for a fresh frame (no input reaches the Mac).
    static let viewOnlyMessages: Set<String> = ["refresh"]

    /// The `caps` message for a backend's input capabilities.
    /// None for a view-only session (it takes no input) or a backend with none.
    static func capabilitiesMessage(for capabilities: [String], viewOnly: Bool) -> ScreenHostMessage? {
        guard !viewOnly, !capabilities.isEmpty else { return nil }
        return ScreenHostMessage(t: ScreenHostMessage.capabilitiesType, s: capabilities.joined(separator: ","))
    }

    /// Tells the viewer what input this host understands, once, as its
    /// channel opens: before the first displays message, so an older viewer
    /// that reads any host message as displays shows the real ones last.
    private func sendCapabilities(_ session: Session) {
        guard let message = Self.capabilitiesMessage(for: session.backend.inputCapabilities, viewOnly: viewOnly),
              let data = try? JSONEncoder().encode(message) else { return }
        _ = session.link.sendText(String(decoding: data, as: UTF8.self))
    }

    /// Sets the encoder and the source for the session's quality and the
    /// rate both displays agree on. True when the rate changed (the viewer
    /// hears it with the next displays message).
    @discardableResult
    private func applyQuality(_ session: Session) -> Bool {
        let hostRate = session.backend.maximumFrameRate
        let (quality, size, fps, changed) = session.lock.withLock { () -> (ScreenQuality, CGSize, Int, Bool) in
            let size = session.displays.indices.contains(session.current) ? session.displays[session.current] : .zero
            let fps = session.quality.frameRate(hostMaximum: hostRate, viewerMaximum: session.viewerFrameRate)
            defer { session.frameRate = fps }
            return (session.quality, size, fps, session.frameRate != fps)
        }
        session.link.applyVideo(quality, source: size, frameRate: fps)
        session.backend.setFrameRate(fps)
        if changed { log("frame rate: \(fps) fps (this Mac \(hostRate.map(String.init) ?? "?") Hz, viewer \(session.lock.withLock { session.viewerFrameRate }.map(String.init) ?? "?") Hz)") }
        return changed
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
// crash-allow: mutable state is read and written only under `lock`; `client` is an actor.
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

/// The phone side of a screen stream: joins the room, receives the screen
/// track, and sends input. Callbacks arrive on arbitrary threads.
// crash-allow: the connection's mutable state is behind `lock`; the owner sets the public callbacks before connect().
public final class ScreenStreamViewer: @unchecked Sendable {
    // @unchecked: mutable state is behind `lock`.
    public var onVideo: (@Sendable (VideoTrackBox) -> Void)?
    public var onDisplays: (@Sendable (ScreenHostMessage) -> Void)?
    /// The host's `caps` list (``ScreenHostMessage/pixelScrollCapability``, ...),
    /// once after the channel opens; a host that sends none predates them
    /// (send only line scrolls).
    public var onCapabilities: (@Sendable ([String]) -> Void)?
    public var onState: (@Sendable (String?) -> Void)?
    public var onPath: (@Sendable (String) -> Void)?
    /// A STUN or TURN server gave no candidate (`icecandidateerror`), for saying why a relay path failed.
    public var onICEError: (@Sendable (ICECandidateError) -> Void)?
    /// The connection stalled (true: no picture coming) or recovered (false).
    public var onStall: (@Sendable (Bool) -> Void)?
    /// How long `connect()` waits for the input channel to open (a reconnect's
    /// last try gets only what is left of its deadline).
    public var openTimeout: TimeInterval = 30
    /// The data channel message that tells the host this viewer left.
    public static let byeMessage = #"{"t":"bye"}"#

    /// The signaling for each attempt (0 first); nil when there is no other.
    private let makeSignaling: @Sendable (Int) -> (any ScreenSignaling)?
    private let lock = NSLock()
    private var link: VNCPeerLink?
    private var socket: (any ScreenSignaling)?
    private var tasks: [Task<Void, Never>] = []
    /// libwebrtc removes a track's renderers when its wrapper is released: keep it.
    private var track: VideoTrackBox?
    private var lastButtons: UInt8 = 0
    private var offered = false
    private var isOpen = false
    private var pathReported = false
    /// TURN relay only (ICE transport policy `relay`): for checking the relay path. Off by default.
    private let relayOnly: Bool

    /// A pairing link's room, reopened whenever it drops.
    public convenience init(pairing: VNCPairing, relayOnly: Bool = false) {
        self.init(relayOnly: relayOnly) { _ in RoomSignaling(pairing: pairing, role: "viewer") }
    }

    /// One device hub session (``TicketSignaling``): its ICE servers, and
    /// the session ends when the signaling does (it is never reopened).
    public convenience init(signaling: any ScreenSignaling, relayOnly: Bool = false) {
        self.init(relayOnly: relayOnly) { attempt in attempt == 0 ? signaling : nil }
    }

    init(relayOnly: Bool, makeSignaling: @escaping @Sendable (Int) -> (any ScreenSignaling)?) {
        self.makeSignaling = makeSignaling
        self.relayOnly = relayOnly
    }

    /// Connects; returns when the input channel is open (video follows).
    /// Once open, only WebRTC ends the session (`onState`): a dropped room
    /// connection is reopened quietly, and the Mac's room going away and
    /// coming back does not touch the running stream.
    public func connect() async throws {
        guard let first = makeSignaling(0) else { throw RFBError.transport("signaling: none") }
        let ice = try await first.iceServers()
        let link = try VNCPeerLink(iceServers: ice, relayOnly: relayOnly, preferStreamRelays: false)
        link.onCandidateError = { [weak self] error in self?.onICEError?(error) }
        link.onStall = { [weak self] stalled in self?.onStall?(stalled) }
        lock.withLock { self.link = link }
        let opened = OpenSignal()
        let peerTask = Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await self?.lock.withLock({ self?.socket })?.send(.candidate(ScreenICECandidate(message)))
                case .open:
                    self?.lock.withLock { self?.isOpen = true }
                    opened.fire(nil)
                case let .video(track):
                    self?.lock.withLock { self?.track = track }
                    self?.onVideo?(track)
                case let .message(data):
                    guard let message = try? JSONDecoder().decode(ScreenHostMessage.self, from: data) else { break }
                    if let capabilities = Self.capabilities(in: message) {
                        self?.onCapabilities?(capabilities)
                    } else if Self.isDisplays(message) {
                        self?.onDisplays?(message)
                    }
                case let .path(local, remote):
                    let relay = local == "relay" || remote == "relay"
                    self?.onPath?(relay ? "Relay" : "Direct")
                    // The hub records the session's path once (`sessions.path`).
                    if let self, lock.withLock({ () -> Bool in defer { pathReported = true }; return !pathReported }) {
                        try? await lock.withLock({ socket })?.send(.path(relay: relay))
                    }
                case .closed:
                    opened.fire(RFBError.connectionClosed)
                    // Before open, connect() reports the failure (it throws); reporting it here
                    // too would count one failed attempt as two drops.
                    if self?.lock.withLock({ self?.isOpen }) == true { self?.onState?("The connection closed.") }
                }
            }
        }
        let signalTask = Task { [weak self, makeSignaling] in
            var delay = 1.0
            var attempt = 0
            var next: (any ScreenSignaling)? = first
            while !Task.isCancelled, let self, let socket = next {
                lock.withLock { self.socket = socket }
                do {
                    for try await message in socket.messages() {
                        delay = 1
                        try await handleSignal(message, link: link, opened: opened)
                    }
                } catch {
                    guard lock.withLock({ isOpen }) else {
                        let detail = (error as? ScreenSignalingError)?.description ?? error.localizedDescription
                        opened.fire(RFBError.transport("signaling: \(detail)"))
                        return
                    }
                }
                socket.close()
                attempt += 1
                next = makeSignaling(attempt)
                guard next != nil else { break }
                try? await Task.sleep(for: .seconds(delay)) // room reconnect backoff
                delay = min(delay * 2, 15)
            }
            // A session's only signaling ended before the channel opened: connect() fails now, not at its deadline.
            if let self, !lock.withLock({ self.isOpen }) { opened.fire(RFBError.transport("signaling ended")) }
        }
        lock.withLock { tasks = [peerTask, signalTask] }
        do {
            try await opened.wait(timeout: openTimeout)
        } catch {
            // A connect that failed leaves nothing behind: its room socket would
            // otherwise offer to the host when it next joins and open a session
            // nobody sees (the host shows a viewer that is not there).
            close()
            throw error
        }
    }

    private func handleSignal(_ message: ScreenSignal, link: VNCPeerLink, opened: OpenSignal) async throws {
        switch message {
        case .hello(peerPresent: true), .peerJoined:
            // One offer per session; the host's room reconnecting is not a new viewer.
            guard lock.withLock({ () -> Bool in
                defer { offered = true }
                return !offered
            }) else { return }
            let sdp = try await link.offer(label: "input", receiveVideo: true, unorderedLabel: "pointer")
            try await lock.withLock({ socket })?.send(.offer(sdp))
        case let .answer(sdp):
            try await link.accept(answer: sdp)
        case let .candidate(candidate):
            await link.add(candidate: candidate.message)
        case .peerLeft:
            guard !lock.withLock({ isOpen }) else { return }
            opened.fire(RFBError.transport("the Mac's host left"))
            link.close()
        case .bye:
            // The session is over (the host left it, or the hub ended it). Once
            // open, closing the link reports it through onState.
            if !lock.withLock({ isOpen }) { opened.fire(RFBError.transport("the session ended")) }
            link.close()
        case .hello, .offer, .path:
            break
        }
    }

    /// Whether a host message is the displays message (`onDisplays`).
    static func isDisplays(_ message: ScreenHostMessage) -> Bool {
        message.t == "displays"
    }

    /// The host's input capabilities from its `caps` message; nil for any other message.
    static func capabilities(in message: ScreenHostMessage) -> [String]? {
        guard message.t == ScreenHostMessage.capabilitiesType else { return nil }
        return (message.s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The input message type that reports the viewer's display rate.
    static let frameRateMessage = "fps"

    static func frameRateInput(_ fps: Int) -> ScreenInput { ScreenInput(t: frameRateMessage, i: fps) }

    /// Tells the Mac the most frames per second this viewer's display shows
    /// (sent again by the app after a reconnect and whenever its window
    /// moves to another display). With Auto or Smooth Motion the Mac then
    /// streams at up to 120 fps when its own display can too; a viewer that
    /// never sends it gets 60.
    public func setDisplayFrameRate(_ fps: Int) {
        send(Self.frameRateInput(fps))
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
        /// Totals since the stream started: frames whose packets all arrived,
        /// and frames received but never decoded or shown (`framesDropped`).
        public var framesReceived: Double = 0
        public var framesDropped: Double = 0
        /// Seconds spent decoding, in total (with `framesDecoded`: the mean decode time).
        public var totalDecodeTime: Double = 0
        public var freezeCount: Double = 0
        public var packetsLost: Double = 0
    }

    public func videoStats() async -> VideoStats {
        guard let link = lock.withLock({ link }) else { return VideoStats() }
        return await link.videoStats()
    }

    /// Ends the session: an open channel first tells the host (`bye`), so it
    /// ends at once instead of waiting for WebRTC to notice the peer is gone.
    public func close() {
        let (link, socket, tasks, open) = lock.withLock { () -> (VNCPeerLink?, (any ScreenSignaling)?, [Task<Void, Never>], Bool) in
            defer { self.tasks.removeAll() }
            return (self.link, self.socket, self.tasks, self.isOpen)
        }
        for task in tasks { task.cancel() }
        socket?.close()
        guard let link else { return }
        guard open, link.sendText(Self.byeMessage) else {
            link.close()
            return
        }
        // Intentional bounded delay: SCTP sends the queued bye before the
        // connection closes (closing at once can discard it).
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200)) // bounded drain before close
            link.close()
        }
    }
}

/// BGRA → NV12 on the GPU (VTPixelTransferSession). The hardware H.264
/// encoder takes NV12; without this libwebrtc converts on the CPU and its
/// overuse detector lowers the frame rate ("limited-by cpu").
// crash-allow: owned by one frame sink and called only from its single frame task, never concurrently.
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
