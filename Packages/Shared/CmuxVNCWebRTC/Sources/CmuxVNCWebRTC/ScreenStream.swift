import CmuxVNC
import CoreGraphics
import CoreVideo
import Foundation
import Network
import os
import VideoToolbox
import WebRTC

/// Viewer → host input and control on the `input` data channel. Pointer
/// coordinates are normalized (0...1) within the display being streamed.
/// `fps` (with `i`) is the most frames per second the viewer's display
/// shows; a host that predates it ignores it and streams at 60.
public struct ScreenInput: Codable, Sendable {
    /// move, scroll, key, chord, text, display, refresh, quality, fps, paste-image
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
    /// For `paste-image`: the chunk count (`i` is the chunk's index), the
    /// image's id and its uniform type identifier (``pasteImage(_:type:id:)``).
    public var n: Int?
    public var id: String?
    public var f: String?

    /// `u` for a scroll in pixels. Send whole pixels and carry the leftover
    /// fraction into the next scroll: a fraction rounds to the nearest pixel,
    /// so many small deltas sent as they come would round to nothing.
    public static let pixelUnit = "px"

    public init(t: String, x: Double? = nil, y: Double? = nil, b: UInt8? = nil, dx: Int? = nil, dy: Int? = nil,
                k: UInt32? = nil, d: Bool? = nil, s: String? = nil, i: Int? = nil, m: [UInt32]? = nil, u: String? = nil,
                n: Int? = nil, id: String? = nil, f: String? = nil) {
        self.t = t; self.x = x; self.y = y; self.b = b; self.dx = dx; self.dy = dy
        self.k = k; self.d = d; self.s = s; self.i = i; self.m = m; self.u = u
        self.n = n; self.id = id; self.f = f
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
        n = try container.decodeIfPresent(Int.self, forKey: .n)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        f = try container.decodeIfPresent(String.self, forKey: .f)
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
    /// Auto and Smooth Motion's bitrate ceiling at 60 fps for a picture of
    /// unknown size: 200 kbit a frame.
    static let adaptiveBitrateAtBaseline = 12_000_000
    /// Auto and Smooth Motion's bitrate ceiling for a known picture: 0.18
    /// bits per encoded pixel per frame, from Petal
    /// (https://github.com/kiruna-labs/petal, Apache-2.0,
    /// `apps/desktop/src-tauri/src/transport/publisher.rs`), which raised it
    /// from 0.13 after small text read "readable, not crisp" at QP 26: the
    /// ceiling is the lever on QP. Clamped to
    /// ``adaptiveBitrateFloor``...``adaptiveBitrateCeiling(frameRate:)``.
    static let adaptiveBitsPerPixelFrame = 0.18
    /// The least ceiling a known picture gets (Petal's 4 Mbps).
    static let adaptiveBitrateFloor = 4_000_000
    /// The most a known picture asks for: Petal's 16 Mbps, and never less
    /// than 200 kbit a frame (24 Mbps at 120 fps, as before), so a
    /// high-rate stream keeps its per-frame budget.
    static func adaptiveBitrateCeiling(frameRate: Int) -> Int {
        max(16_000_000, adaptiveBitrateAtBaseline / baselineFrameRate * frameRate)
    }

    /// Auto and Smooth Motion's bitrate ceiling for a `width`×`height`
    /// picture as encoded (after ``Settings/scaleDown``) at `frameRate`.
    /// A picture of unknown size keeps 200 kbit a frame.
    static func adaptiveBitrate(width: Double, height: Double, frameRate: Int) -> Int {
        guard width > 0, height > 0 else { return adaptiveBitrateAtBaseline / baselineFrameRate * frameRate }
        let wanted = Int((adaptiveBitsPerPixelFrame * width * height * Double(frameRate)).rounded())
        return min(max(wanted, adaptiveBitrateFloor), adaptiveBitrateCeiling(frameRate: frameRate))
    }
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
    /// Auto and Smooth Motion's bitrate ceiling follows the encoded pixels
    /// and the frame rate (``adaptiveBitrate(width:height:frameRate:)``): a
    /// full Retina display gets 16 Mbps at 60 fps and 24 at 120, a small
    /// picture less (1280×800 at 60: about 11 Mbps). At a fixed ceiling a
    /// faster stream would give every frame fewer bits and text would blur in motion.
    /// It is a ceiling, not a target: WebRTC's congestion control still sets
    /// the rate from the network, and a still screen sends next to nothing.
    /// Above 60 fps they also scale the picture down just enough to stay
    /// within ``maximumEncodedPixelRate``: a 16" MacBook Pro's 3456×2234 goes
    /// out at about 2154×1392 at 120 fps (60 fps keeps the full size).
    func settings(sourceWidth: Int = 0, sourceHeight: Int, frameRate: Int = ScreenQuality.baselineFrameRate) -> Settings {
        func scale(to height: Int) -> Double { sourceHeight > height ? Double(sourceHeight) / Double(height) : 1 }
        let fps = min(max(frameRate, Self.baselineFrameRate), Self.maximumFrameRate)
        let pixelRate = Double(sourceWidth) * Double(sourceHeight) * Double(fps)
        let fitEncoder = fps > Self.baselineFrameRate && pixelRate > Double(Self.maximumEncodedPixelRate)
            ? (pixelRate / Double(Self.maximumEncodedPixelRate)).squareRoot() : 1
        let adaptiveBitrate = Self.adaptiveBitrate(width: Double(sourceWidth) / fitEncoder,
                                                   height: Double(sourceHeight) / fitEncoder, frameRate: fps)
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
    /// For `telepointers`: the Mac's pointer (the person's) and the agent's,
    /// each as a fraction (0–1, top left origin) of the streamed display;
    /// absent when it is off that display or hidden.
    public var person: Pointer?
    public var agent: Pointer?
    /// For `telepointers`: the id of the person's cursor shape, sent before
    /// as a ``cursorShapeType`` message (only to a viewer that said
    /// ``cursorShapeCapability``).
    public var shape: String?
    /// For `cursor` (``cursorShapeType``): the Mac's cursor image.
    public var cursor: ScreenCursorShape?
    /// For `paste-image`: the image the answer is about.
    public var id: String?

    /// A pointer position as a fraction of the streamed display.
    public struct Pointer: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// `t` of the message a host sends once its input channel opens.
    public static let capabilitiesType = "caps"
    /// The host posts `scroll` with `u: "px"` as pixel (continuous) scrolling.
    public static let pixelScrollCapability = "scroll-px"
    /// Pointer events carry the modifier keys held down (a modifier `key` down, then a click, is a modified click).
    public static let modifiedPointerCapability = "mods"
    /// `t` of the host's pointer positions (``person``, ``agent``), sent
    /// while they change to a viewer that draws pointers itself.
    public static let telepointersType = "telepointers"
    /// What a viewer that draws pointers from ``telepointersType`` messages
    /// says in its own `caps` message: the host then leaves the cursor out of
    /// the picture (Petal's telepointers: cursors as metadata, never pixels).
    /// An older viewer never says it and keeps the cursor in the picture.
    public static let telepointersCapability = "telepointers"
    /// `t` of the host's cursor image (``cursor``), once per shape.
    public static let cursorShapeType = "cursor"
    /// What a viewer that draws the Mac's own cursor image says in its `caps`
    /// message, with ``telepointersCapability``: the host then sends each
    /// shape (``cursorShapeType``) and names it in ``shape``.
    public static let cursorShapeCapability = "cursor-shape"
}

// In an extension: an init in the struct's body would replace its memberwise init.
extension ScreenHostMessage {
    /// `t` of the host's ``ScreenSourceState`` (in `s`), sent when it changes.
    public static let sourceType = "source"

    /// The host's source state message.
    public init(source state: ScreenSourceState) {
        self.init(t: Self.sourceType, s: state.rawValue)
    }

    /// The source state this message carries; nil for any other message.
    public var sourceState: ScreenSourceState? {
        guard t == Self.sourceType else { return nil }
        return s.flatMap(ScreenSourceState.init(rawValue:))
    }
}

/// What the Mac's screen shows the capture: the picture, or nothing because
/// the session is locked or the display asleep. A locked, dark Mac streams a
/// few idle black frames with stats that look healthy ("3 fps, 0 KB/s, 12 ms"
/// on Leo's NIGHTLY, 2026-11-17), so the host says which (``ScreenHostMessage/sourceType``)
/// and the viewer tells the person. An older host never says (live); an
/// older viewer ignores the message.
public enum ScreenSourceState: String, Sendable, Equatable, CaseIterable {
    case live
    case locked
    /// The display sleeps (the session may be unlocked).
    case asleep

    /// Locked wins over asleep: a locked Mac whose display slept needs unlocking either way.
    public init(locked: Bool, asleep: Bool) {
        self = locked ? .locked : (asleep ? .asleep : .live)
    }
}

/// Reads whether the Mac's session is locked and its display asleep: the
/// system's (``ScreenCaptureBackend``), or a test's.
public protocol ScreenSourceProbe: Sendable {
    func read() -> ScreenSourceState
}

/// Reports a source's state: at the first ``check()``, then whenever a
/// later check reads another, until ``stop()``. Its owner checks on a tick
/// it already runs and on frames that arrive while not live, so there is no
/// observer and no timer of its own.
public final class ScreenSourceMonitor: Sendable {
    private struct State {
        var last: ScreenSourceState?
        var stopped = false
    }

    private let probe: any ScreenSourceProbe
    private let changed: @Sendable (ScreenSourceState) -> Void
    private let current = OSAllocatedUnfairLock(initialState: State())

    public init(probe: any ScreenSourceProbe, changed: @escaping @Sendable (ScreenSourceState) -> Void) {
        self.probe = probe
        self.changed = changed
    }

    /// The state the last check read; nil before the first.
    public var state: ScreenSourceState? { current.withLock { $0.last } }

    public func check() {
        // Read under the lock: two checks at once never report an older reading last.
        let report = current.withLock { [probe] state -> ScreenSourceState? in
            guard !state.stopped else { return nil }
            let now = probe.read()
            guard state.last != now else { return nil }
            state.last = now
            return now
        }
        if let report { changed(report) }
    }

    public func stop() {
        current.withLock { $0.stopped = true }
    }
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
    /// Whether the cursor is drawn into the picture (on until a viewer draws
    /// pointers itself). A source that can't leave it out ignores this.
    func setDrawsCursor(_ draws: Bool)
    /// The streaming display's frame in global display coordinates (points,
    /// top left origin, as `CGEvent` locations); nil when the source does not know.
    var displayFrame: CGRect? { get }
    /// Captures at most `pixels` on the picture's long edge (the viewer's
    /// demand; nil: the display's own size). Only for a source that
    /// ``scalesToDemand``.
    func setMaximumLongEdge(_ pixels: Int?)
    /// Whether ``setMaximumLongEdge(_:)`` scales the picture. A source that
    /// can't (the Screen Sharing loopback) keeps the full size, and so does
    /// the encoder's bitrate ceiling.
    var scalesToDemand: Bool { get }
    /// Puts an image on this Mac's pasteboard and pastes it (⌘V) where the
    /// person's focus is: the viewer's Paste Image. False when the source
    /// can't (it does not list ``ScreenHostMessage/pasteImageCapability``)
    /// or the bytes are not an image.
    func pasteImage(_ data: Data, type: String) -> Bool
    /// Calls `changed` with the source's state (live, locked, display
    /// asleep) now and on each change, until ``stop()``. A source that
    /// can't tell (the Screen Sharing loopback) never calls it.
    func observeSourceState(_ changed: @escaping @Sendable (ScreenSourceState) -> Void)
}

/// Sources that do not know their display's rate (the Screen Sharing
/// loopback) report none and keep their own pace: the stream stays at 60.
public extension ScreenBackend {
    var maximumFrameRate: Int? { nil }
    var inputCapabilities: [String] { [] }
    func setFrameRate(_ fps: Int) {}
    func setDrawsCursor(_ draws: Bool) {}
    var displayFrame: CGRect? { nil }
    func setMaximumLongEdge(_ pixels: Int?) {}
    var scalesToDemand: Bool { false }
    func pasteImage(_ data: Data, type: String) -> Bool { false }
    func observeSourceState(_ changed: @escaping @Sendable (ScreenSourceState) -> Void) {}
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
        /// Under `lock`: the session's tasks, and whether it ended (a task
        /// started after that is cancelled at once).
        var tasks: [Task<Void, Never>] = []
        var ended = false
        let lock = NSLock()

        /// Keeps `task` to cancel when the session ends; cancels it at once
        /// when it already did (the viewer left while it started).
        func add(_ task: Task<Void, Never>) {
            let ended = lock.withLock { () -> Bool in
                if !self.ended { tasks.append(task) }
                return self.ended
            }
            if ended { task.cancel() }
        }
        var last: (buffer: CVPixelBuffer, crop: CGRect)?
        var idle = ScreenStreamHost.IdleRefresh()
        var displays: [CGSize] = []
        var current = 0
        var quality = ScreenQuality.auto
        /// The most frames per second the viewer's display shows (nil: not reported, an older viewer).
        var viewerFrameRate: Int?
        /// The rate the stream is set to (nil until the source reports its displays).
        var frameRate: Int?
        /// Pictures the source delivered since the last encoder log line (idle refreshes not counted).
        var captured = 0
        /// The size the viewer needs (``ViewerDemand``); full size until it reports one.
        var demand: ViewerDemand
        /// The data channel opened: from here on only WebRTC ends the session.
        var opened = false
        /// The viewer draws pointers itself (it said ``ScreenHostMessage/telepointersCapability``).
        var telepointers = false
        /// The viewer draws the Mac's cursor image (it said ``ScreenHostMessage/cursorShapeCapability``).
        var cursorShapes = false
        /// The image the viewer is pasting, chunk by chunk.
        var images = ScreenImageAssembler()
        /// The source state the viewer last heard (live until the host says otherwise).
        var source = ScreenSourceState.live
        init(link: VNCPeerLink, backend: any ScreenBackend, rules: ScreenRules) {
            self.link = link
            self.backend = backend
            demand = ViewerDemand(rules: rules)
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
    /// The rules the host asks (``ScreenRules``; none: full size, the cursor in the picture, no focus signals).
    private let rules: ScreenRules
    private let lock = NSLock()
    private var session: Session?
    /// The device hub session ``serve(_:)`` is serving, for `bye` on disconnect.
    private var ticketSignaling: (any ScreenSignaling)?
    /// Where the agent's pointer is (Computer Use), in global display
    /// coordinates (points, top left origin, as `CGEvent` locations); nil
    /// when it shows none. Read about 60 times a second while a viewer draws
    /// pointers itself. Set by the app; nil by default (no agent pointer).
    public var agentPointer: (@Sendable () -> CGPoint?)? {
        get { lock.withLock { agentPointerSource } }
        set { lock.withLock { agentPointerSource = newValue } }
    }
    private var agentPointerSource: (@Sendable () -> CGPoint?)?

    /// Called from the host's tasks with each `Event` (any thread).
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.withLock { eventSink } }
        set { lock.withLock { eventSink = newValue } }
    }
    private var eventSink: (@Sendable (Event) -> Void)?

    public init(pairing: VNCPairing, viewOnly: Bool = false, backend: @escaping @Sendable () -> any ScreenBackend,
                rules: ScreenRules = ScreenRules(), log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.rules = rules
        self.pairing = pairing
        name = pairing.name
        self.viewOnly = viewOnly
        makeBackend = backend
        self.log = log
    }

    /// A host for device hub sessions (``serve(_:)``); no room.
    public init(name: String, viewOnly: Bool = false, backend: @escaping @Sendable () -> any ScreenBackend,
                rules: ScreenRules = ScreenRules(), log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.rules = rules
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
        let session = Session(link: link, backend: makeBackend(), rules: rules)
        lock.withLock { self.session = session }
        session.add(Task { [weak self] in
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await signaling.send(.candidate(ScreenICECandidate(message)))
                case .open: self?.start(session)
                case let .message(data): self?.handleInput(data, session: session)
                case .closed:
                    self?.endSession(ifCurrent: session)
                    // A transient media failure must leave an approved hub session alive so the
                    // viewer can obtain a fresh ticket. Explicit viewer close still sends bye below.
                    if signaling.endsSessionOnClose { signaling.close() }
                case let .path(local, remote):
                    self?.log("path: this Mac \(local) ↔ viewer \(remote)\(local == "relay" || remote == "relay" ? " (TURN relay)" : " (direct)")")
                case .video, .focus: break
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
        startFocusSignals(session)
        // Locked or display asleep: the picture is black, so the viewer hears why (and when it ends).
        session.backend.observeSourceState { [weak self] state in self?.sendSource(state, session: session) }
        session.add(Task { [weak self] in
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
        session.add(Task { [weak self] in
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
        // Idle refresh: capture sends nothing while the screen is still, so the
        // last picture is repeated a few times for the encoder to sharpen it,
        // then nothing goes out until something asks again (IdleRefresh).
        session.add(Task { [weak self] in
            var requests: Int?
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(IdleRefresh.periodNs)) // idle refresh period
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let idle = session.lock.withLock { session.idle.isIdle(now: now) }
                // A still screen: a viewer that lost a picture asks for a keyframe (PLI/FIR).
                // The count is read only on a still screen, from its first still period on.
                if !idle {
                    requests = nil
                } else if let count = await session.link.keyframeRequests() {
                    if let requests, count > requests { session.lock.withLock { session.idle.keyframeRequested(now: now) } }
                    requests = count
                }
                let stale = session.lock.withLock { () -> (CVPixelBuffer, CGRect)? in
                    guard let last = session.last, session.idle.repeatNow(now: DispatchTime.now().uptimeNanoseconds) else { return nil }
                    return (last.buffer, last.crop)
                }
                if let stale { repeatLast(stale.0, crop: stale.1, session: session) }
            }
        })
    }

    /// When the host repeats the last picture while the source sends none.
    /// A new picture, a quality, size or rate change, the viewer's `refresh`
    /// and a keyframe request each allow ``repeats`` repeats ``periodNs``
    /// apart; a still screen then sends nothing at all (RFD 0088 slice 3b:
    /// it used to send 2 pictures a second forever).
    struct IdleRefresh {
        static let periodNs: UInt64 = 500_000_000
        /// Enough for VideoToolbox to bring a still picture to full quality.
        static let repeats = 4
        private(set) var remaining = 0
        private var lastPushNs: UInt64 = 0

        /// A picture went to the encoder (new or repeated).
        mutating func pushed(now: UInt64, fresh: Bool) {
            lastPushNs = now
            if fresh { remaining = Self.repeats }
        }

        /// Something needs the picture encoded again.
        mutating func arm() { remaining = Self.repeats }

        /// How soon after a picture a keyframe request (PLI/FIR) still means
        /// the viewer lost it. libwebrtc's receiver also asks for a keyframe
        /// on its own 3 s after the last frame while packets are recent;
        /// answering that one would repeat a still screen forever.
        static let lossRequestWindowNs: UInt64 = 2_000_000_000

        /// The viewer asked for a keyframe: re-arm only when it follows a
        /// picture closely enough to be a loss, not the receiver's timeout.
        mutating func keyframeRequested(now: UInt64) {
            if lastPushNs != 0, now &- lastPushNs < Self.lossRequestWindowNs { arm() }
        }

        /// No picture for a period and none left to repeat.
        func isIdle(now: UInt64) -> Bool { remaining == 0 && stale(now: now) }

        /// Whether to repeat the last picture now; counts the repeat.
        mutating func repeatNow(now: UInt64) -> Bool {
            guard remaining > 0, stale(now: now) else { return false }
            remaining -= 1
            return true
        }

        private func stale(now: UInt64) -> Bool { now &- lastPushNs > Self.periodNs * 9 / 10 }
    }

    /// The encoder needs a fresh picture now (a quality step, the viewer's
    /// `refresh`): push the last one at once and allow its repeats again.
    private func refreshSoon(_ session: Session) {
        let last = session.lock.withLock { () -> (buffer: CVPixelBuffer, crop: CGRect)? in
            session.idle.arm()
            return session.last
        }
        if let last { repeatLast(last.buffer, crop: last.crop, session: session) }
    }

    private func repeatLast(_ buffer: CVPixelBuffer, crop: CGRect, session: Session) {
        session.lock.withLock { session.idle.pushed(now: DispatchTime.now().uptimeNanoseconds, fresh: false) }
        session.video.push(buffer, crop: crop, timestampNs: Int64(DispatchTime.now().uptimeNanoseconds))
    }

    private func push(_ buffer: CVPixelBuffer, crop: CGRect, session: Session) {
        session.lock.withLock {
            session.last = (buffer, crop)
            session.idle.pushed(now: DispatchTime.now().uptimeNanoseconds, fresh: true)
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

    /// Tells the viewer the source's state when it changed from what it last heard.
    private func sendSource(_ state: ScreenSourceState, session: Session) {
        let changed = session.lock.withLock { () -> Bool in
            guard !session.ended, session.source != state else { return false }
            session.source = state
            return true
        }
        guard changed, let data = try? JSONEncoder().encode(ScreenHostMessage(source: state)) else { return }
        log("source: \(state.rawValue)")
        _ = session.link.sendText(String(decoding: data, as: UTF8.self))
    }

    /// The viewer's display rate from its `fps` report; nil for any other
    /// message or a rate no display has.
    static func reportedFrameRate(_ input: ScreenInput) -> Int? {
        guard input.t == ScreenStreamViewer.frameRateMessage, let fps = input.i, (1 ... 1000).contains(fps) else { return nil }
        return fps
    }

    /// What a viewer's `caps` message says it draws: pointers, and the Mac's
    /// cursor image (cmux-rd-screen `screen_cursor_caps`; neither without
    /// the rules, so the cursor stays in the picture).
    static func viewerDraws(_ input: ScreenInput, rules: ScreenRules) -> (pointers: Bool, shapes: Bool) {
        struct Request: Encodable { var t: String, s: String? }
        struct Answer: Decodable { var pointers: Bool, shapes: Bool }
        let answer = rules.ask("screen_cursor_caps", Request(t: input.t, s: input.s), as: Answer.self)
        return (answer?.pointers ?? false, answer?.shapes ?? false)
    }

    /// `point` (global display coordinates) as a fraction of `display`;
    /// nil when it is off that display.
    static func fraction(of point: CGPoint?, in display: CGRect?) -> ScreenHostMessage.Pointer? {
        guard let point, let display, display.width > 0, display.height > 0, display.contains(point) else { return nil }
        return .init(x: Double((point.x - display.minX) / display.width), y: Double((point.y - display.minY) / display.height))
    }

    /// This Mac's pointer in global display coordinates (none off macOS).
    static func pointerLocation() -> CGPoint? {
        #if os(macOS)
        CGEvent(source: nil)?.location
        #else
        nil
        #endif
    }

    /// Sends the pointers to a viewer that draws them: about 60 times a
    /// second, only when one moved, on the unordered `pointer` channel
    /// (latest wins; the ordered channel for a viewer without one).
    private func startTelepointers(_ session: Session) {
        let rules = rules
        let task = Task { [weak self] in
            var last: (ScreenHostMessage.Pointer?, ScreenHostMessage.Pointer?, String?)?
            var lastSent = DispatchTime.now()
            // The Mac's cursor image, for a viewer that draws it (cursor-shape).
            var shapes = ShapeSender(rules: rules)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16)) // telepointer sampling period (60 Hz)
                guard let self else { return }
                let display = session.backend.displayFrame
                let person = Self.fraction(of: Self.pointerLocation(), in: display)
                let agent = Self.fraction(of: agentPointer?(), in: display)
                let shape = await shapes.current(session: session, display: display)
                // Unchanged: nothing to send, but once a second anyway (an unordered message may be lost).
                let stale = DispatchTime.now().uptimeNanoseconds - lastSent.uptimeNanoseconds > 1_000_000_000
                if let last, last.0 == person, last.1 == agent, last.2 == shape, !stale { continue }
                last = (person, agent, shape)
                lastSent = .now()
                var message = ScreenHostMessage(t: ScreenHostMessage.telepointersType)
                message.person = person
                message.agent = agent
                message.shape = shape
                if let data = try? JSONEncoder().encode(message) {
                    let text = String(decoding: data, as: UTF8.self)
                    if !session.link.sendText(text, on: "pointer") { _ = session.link.sendText(text) }
                }
            }
        }
        session.add(task)
    }

    /// Follow mode (FocusSignals.swift): the pointer, caret, focused window
    /// and screen damage in the streamed display's pixels, only on a `focus`
    /// channel the viewer opened (an older viewer gets none).
    private func startFocusSignals(_ session: Session) {
        guard rules.installed else { return }
        let link = session.link
        let producer = FocusSignalProducer(rules: rules, probe: FocusSignalProducer.systemProbe(), geometry: { [weak session] in
            guard let session, let display = session.backend.displayFrame else { return nil }
            let pixels = session.lock.withLock { session.displays.indices.contains(session.current) ? session.displays[session.current] : nil }
            return pixels.map { FocusGeometry(display: display, pixels: $0) }
        }, send: { link.sendText($0, onlyOn: VNCPeerLink.focusLabel) })
        (session.backend as? any ScreenDamageSource)?.onDamage = { rects, size in producer.damage(rects, captured: size) }
        session.add(Task { await producer.run { link.hasOpenChannel(VNCPeerLink.focusLabel) } })
    }

    /// Sends the Mac's cursor image to a viewer that draws it: each new
    /// shape once, on the ordered channel, before the telepointers that name it.
    private struct ShapeSender {
        #if os(macOS)
        private let reader: ScreenCursorReader
        #endif
        private var delivery: CursorShapeDelivery

        init(rules: ScreenRules) {
            #if os(macOS)
            reader = ScreenCursorReader(rules: rules)
            #endif
            delivery = CursorShapeDelivery(rules: rules)
        }

        /// The id of the cursor's shape now (nil: the viewer draws no shapes, or none is known yet).
        mutating func current(session: Session, display: CGRect?) async -> String? {
            guard session.lock.withLock({ session.cursorShapes }), let display else { return nil }
            #if os(macOS)
            let read = await reader.read(display: display)
            #else
            let read: ScreenCursorShape? = nil
            #endif
            return delivery.current(read: read, display: display) { session.link.sendText($0) }
        }
    }

    /// The ordered cursor messages and the last shape accepted by the link
    /// (cmux-rd-screen's `CursorShapeDelivery`: each shape once per display,
    /// a refused send retried without another read, a fresh shape
    /// superseding an unsent one).
    struct CursorShapeDelivery {
        private let rules: ScreenRules
        private var state: ScreenJSON?

        init(rules: ScreenRules) {
            self.rules = rules
        }

        mutating func current(read: ScreenCursorShape?, display: CGRect, sendText: (String) -> Bool) -> String? {
            struct Prepare: Encodable { var delivery: ScreenJSON?, read: ScreenCursorShape?, display: ScreenRect }
            struct Prepared: Decodable { var delivery: ScreenJSON, text: String? }
            struct Finish: Encodable { var delivery: ScreenJSON, delivered: Bool }
            struct Finished: Decodable { var delivery: ScreenJSON, shape: String? }
            guard let prepared = rules.ask("screen_cursor_prepare", Prepare(delivery: state, read: read, display: ScreenRect(display)),
                                           as: Prepared.self) else { return nil }
            // A refused send must neither forget the payload nor record it as delivered.
            let delivered = prepared.text.map(sendText) ?? false
            guard let finished = rules.ask("screen_cursor_finish", Finish(delivery: prepared.delivery, delivered: delivered),
                                           as: Finished.self) else { return nil }
            state = finished.delivery
            return finished.shape
        }
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
        if input.t == ScreenHostMessage.capabilitiesType {
            // The viewer's own capabilities, not input: view-only sessions too.
            let (draws, shapes) = Self.viewerDraws(input, rules: rules)
            guard draws, !session.lock.withLock({ session.telepointers }) else { return }
            session.lock.withLock {
                session.telepointers = true
                session.cursorShapes = shapes
            }
            log("viewer draws pointers: cursor left out of the picture")
            session.backend.setDrawsCursor(false)
            startTelepointers(session)
            return
        }
        if input.t == ScreenHostMessage.pasteImageType {
            let answer = Self.takeImageChunk(input, backend: session.backend, viewOnly: viewOnly) { chunk in
                session.lock.withLock { session.images.take(chunk) }
            }
            guard let answer else { return }
            log("paste image: \(answer.s ?? "-")")
            if let data = try? JSONEncoder().encode(answer) {
                _ = session.link.sendText(String(decoding: data, as: UTF8.self))
            }
            return
        }
        if input.t == ScreenStreamViewer.viewDemandMessage {
            // The viewer's display, not input: view-only sessions too.
            applyDemand(input, session: session)
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
        if input.t == ScreenStreamViewer.refreshMessage { refreshSoon(session) } // and the backend's own refresh below (VNC asks for a full update)
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

    /// One `paste-image` chunk: kept until the image is whole, then pasted
    /// by the backend. The answer for the viewer, or nil while more chunks
    /// are to come. A view-only session, or a backend that does not paste
    /// images, refuses every image.
    static func takeImageChunk(_ input: ScreenInput, backend: any ScreenBackend, viewOnly: Bool,
                               take: (ScreenInput) -> ScreenImageAssembler.Step) -> ScreenHostMessage? {
        guard !viewOnly, backend.inputCapabilities.contains(ScreenHostMessage.pasteImageCapability) else {
            // Answer once per image, not once per chunk.
            return input.i == 0 ? ScreenHostMessage(pasteImage: .refused, id: input.id) : nil
        }
        switch take(input) {
        case .partial, .ignored: return nil
        case let .failed(outcome, id): return ScreenHostMessage(pasteImage: outcome, id: id)
        case let .complete(data, type, id): return ScreenHostMessage(pasteImage: backend.pasteImage(data, type: type) ? .pasted : .refused, id: id)
        }
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

    /// Takes a viewer's `view` report: once a new size held long enough
    /// (``ViewerDemand``), the source captures at it and the encoder's
    /// bitrate follows the smaller picture. The demand follows the viewer
    /// under a fixed preset too, so going back to Auto starts at its size.
    private func applyDemand(_ input: ScreenInput, session: Session) {
        guard let longEdge = input.i, session.backend.scalesToDemand else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let changed = session.lock.withLock { () -> Int?? in
            let display = session.displays.indices.contains(session.current) ? session.displays[session.current] : .zero
            guard session.demand.report(longEdge: longEdge, displayLongEdge: Int(max(display.width, display.height)),
                                        pinch: input.d == true, now: now),
                  session.quality == .auto || session.quality == .smooth else { return nil }
            return .some(session.demand.cap)
        }
        guard let changed else { return }
        log("viewer demand: \(changed.map { "\($0) px long edge" } ?? "full size")")
        applyQuality(session)
    }

    /// Sets the encoder and the source for the session's quality and the
    /// rate both displays agree on. True when the rate changed (the viewer
    /// hears it with the next displays message).
    @discardableResult
    private func applyQuality(_ session: Session) -> Bool {
        let hostRate = session.backend.maximumFrameRate
        let (quality, size, cap, fps, changed) = session.lock.withLock { () -> (ScreenQuality, CGSize, Int?, Int, Bool) in
            let display = session.displays.indices.contains(session.current) ? session.displays[session.current] : .zero
            let cap = session.demand.captureCap(quality: session.quality, scales: session.backend.scalesToDemand)
            let size = ViewerDemand.fit(display, cap: cap, rules: rules)
            let fps = session.quality.frameRate(hostMaximum: hostRate, viewerMaximum: session.viewerFrameRate)
            defer { session.frameRate = fps }
            return (session.quality, size, cap, fps, session.frameRate != fps)
        }
        session.link.applyVideo(quality, source: size, frameRate: fps)
        session.backend.setFrameRate(fps)
        session.backend.setMaximumLongEdge(cap)
        refreshSoon(session) // new encoder settings take effect on the next picture, which a still screen does not send
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
        let tasks = ended.lock.withLock { () -> [Task<Void, Never>] in
            ended.ended = true
            defer { ended.tasks.removeAll() }
            return ended.tasks
        }
        for task in tasks { task.cancel() }
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

    /// A viewer's pointer fraction as a pixel on the display: kept on the display, and the display's origin for a
    /// fraction that is no number. The fraction comes off the wire; `Int(_:)` of a huge or non-finite product traps
    /// (the class of the screen-share host SIGTRAP, hq#22239).
    static func pixel(_ fraction: Double?, from origin: CGFloat, across length: CGFloat) -> Int {
        guard let fraction, fraction.isFinite else { return Int(exactly: origin.rounded(.down)) ?? 0 }
        let value = origin + CGFloat(min(max(fraction, 0), 1)) * length
        return Int(exactly: value.rounded(.towardZero)) ?? 0
    }

    private func apply(_ input: ScreenInput, client: VNCClient) async {
        let display = lock.withLock { displays.indices.contains(current) ? displays[current] : .zero }
        let x = Self.pixel(input.x, from: display.minX, across: display.width)
        let y = Self.pixel(input.y, from: display.minY, across: display.height)
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
    /// The host's pointer positions (``ScreenHostMessage/person``,
    /// ``ScreenHostMessage/agent``), after ``drawPointers()``; any thread.
    public var onTelepointers: (@Sendable (ScreenHostMessage) -> Void)?
    /// The Mac's cursor image (``ScreenHostMessage/cursor``), once per shape,
    /// before the telepointers that name it; any thread.
    public var onCursorShape: (@Sendable (ScreenCursorShape) -> Void)?
    /// The host's answer to ``pasteImage(_:type:id:)`` and the image id it names; any thread.
    public var onPasteImage: (@Sendable (ScreenHostMessage.PasteImageOutcome, String?) -> Void)?
    /// The Mac's ``ScreenSourceState`` when it changes; an older host never sends it (live). Any thread.
    public var onSourceState: (@Sendable (ScreenSourceState) -> Void)?
    public var onState: (@Sendable (String?) -> Void)?
    public var onPath: (@Sendable (String) -> Void)?
    /// A STUN or TURN server gave no candidate (`icecandidateerror`), for saying why a relay path failed.
    public var onICEError: (@Sendable (ICECandidateError) -> Void)?
    /// The connection stalled (true: no picture coming) or recovered (false).
    public var onStall: (@Sendable (Bool) -> Void)?
    /// Follow mode: each message on the host's `focus` channel, the UTF-8
    /// JSON of one focus event (cmux-follow-cam's `Event`); any thread. An
    /// older host sends none.
    public var onFocus: (@Sendable (Data) -> Void)?
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
                case let .focus(data):
                    self?.onFocus?(data)
                case let .message(data):
                    guard let message = try? JSONDecoder().decode(ScreenHostMessage.self, from: data) else { break }
                    if let capabilities = Self.capabilities(in: message) {
                        self?.onCapabilities?(capabilities)
                    } else if Self.isDisplays(message) {
                        self?.onDisplays?(message)
                    } else if message.t == ScreenHostMessage.telepointersType {
                        self?.onTelepointers?(message)
                    } else if message.t == ScreenHostMessage.cursorShapeType, let shape = message.cursor {
                        self?.onCursorShape?(shape)
                    } else if let outcome = message.pasteImageOutcome {
                        self?.onPasteImage?(outcome, message.id)
                    } else if let state = message.sourceState {
                        self?.onSourceState?(state)
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
            let sdp = try await link.offer(label: "input", receiveVideo: true, unorderedLabel: "pointer",
                                           focusLabel: VNCPeerLink.focusLabel)
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

    /// The message type that reports how large the viewer shows the stream:
    /// `i` the long edge in device pixels the whole streamed display takes at
    /// the viewer's zoom, `d` true when a pinch just ended (``ViewerDemand``).
    /// An older host ignores it and keeps the full size.
    static let viewDemandMessage = "view"
    /// Asks for the picture again (``ScreenStreamHost/IdleRefresh``; the VNC backend redraws).
    static let refreshMessage = "refresh"

    /// Tells the Mac how large this viewer shows the stream (every 2 s, and
    /// with `pinch` when a zoom ends). Auto and Smooth Motion then capture
    /// no larger than that needs; the fixed presets ignore it.
    public func reportView(longEdge: Int, pinch: Bool) {
        send(ScreenInput(t: Self.viewDemandMessage, d: pinch, i: longEdge))
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

    /// Tells the Mac this viewer draws the pointers itself (sent again by
    /// the app after a reconnect): the Mac leaves its cursor out of the
    /// picture and sends ``onTelepointers`` instead. An older Mac ignores it
    /// and keeps the cursor in the picture.
    public func drawPointers() {
        send(Self.drawPointersInput)
    }

    /// The `caps` report of a viewer that draws pointers and the Mac's own
    /// cursor image (an older Mac reads only `telepointers` from it).
    static let drawPointersInput = ScreenInput(
        t: ScreenHostMessage.capabilitiesType,
        s: [ScreenHostMessage.telepointersCapability, ScreenHostMessage.cursorShapeCapability].joined(separator: ","))

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

    /// Sends an image for the Mac to paste (only to a host whose `caps`
    /// listed ``ScreenHostMessage/pasteImageCapability``): its chunks in
    /// order, waiting while the channel is full. False when nothing could
    /// be sent (no channel, or the image is empty, too large or of another
    /// type); the Mac's answer comes in ``onPasteImage``. Runs off the
    /// caller's actor: up to 20 MB of base64 and JSON never lands on the main thread.
    @concurrent
    public func pasteImage(_ data: Data, type: String, id: String = UUID().uuidString) async -> Bool {
        let messages = ScreenInput.pasteImage(data, type: type, id: id)
        guard !messages.isEmpty, let link = lock.withLock({ link }) else { return false }
        let encoder = JSONEncoder()
        do {
            for message in messages {
                try await link.sendTextPaced(String(decoding: try encoder.encode(message), as: UTF8.self))
            }
        } catch {
            return false
        }
        return true
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
        /// Every byte the nominated path received (video, RTCP, the data channel, headers): what a relay carries.
        public var transportBytesReceived: Double = 0
    }

    public func videoStats() async -> VideoStats {
        guard let link = lock.withLock({ link }) else { return VideoStats() }
        return await link.videoStats()
    }

    /// Ends the session: an open channel first tells the host (`bye`), so it
    /// ends at once instead of waiting for WebRTC to notice the peer is gone.
    public func close(sendBye: Bool = true) {
        let (link, socket, tasks, open) = lock.withLock { () -> (VNCPeerLink?, (any ScreenSignaling)?, [Task<Void, Never>], Bool) in
            defer { self.tasks.removeAll() }
            return (self.link, self.socket, self.tasks, self.isOpen)
        }
        for task in tasks { task.cancel() }
        socket?.close()
        guard let link else { return }
        guard sendBye, open, link.sendText(Self.byeMessage) else {
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
