import Foundation

/// One complete video frame of a streamed Mac browser tab.
public struct BrowserStreamFrame: Sendable {
    /// 0 = the page.
    public var stream: UInt16
    public var frame: UInt32
    public var keyframe: Bool
    /// H.264 Annex-B access unit (SPS and PPS before each IDR).
    public var accessUnit: Data
    /// Host capture time (host monotonic microseconds).
    public var captureMicros: UInt64
    /// When it was complete, on the stream's clock (``BrowserStreamConnection/nowMicros()``).
    public var receivedMicros: UInt64
    /// Capture to complete on the phone (host encode, network, reassembly);
    /// nil until the clock probes have an estimate.
    public var ageMicros: Int64?

    public init(stream: UInt16, frame: UInt32, keyframe: Bool, accessUnit: Data, captureMicros: UInt64,
                receivedMicros: UInt64, ageMicros: Int64?) {
        self.stream = stream
        self.frame = frame
        self.keyframe = keyframe
        self.accessUnit = accessUnit
        self.captureMicros = captureMicros
        self.receivedMicros = receivedMicros
        self.ageMicros = ageMicros
    }
}

/// Counters of one stream.
public struct BrowserStreamStats: Sendable, Equatable {
    public var frames: UInt64 = 0
    public var keyframes: UInt64 = 0
    public var bytes: UInt64 = 0
    public var framesLost: UInt64 = 0
    public var clockOffsetMicros: Int64?
    public var clockRTTMicros: UInt32?
    /// The newest frame came on the link's media lane (RTP), not the
    /// reliable `browser` channel (verify/browser-video-track.md).
    public var videoTrack = false
    /// What carried the newest frame: `track` (a WebRTC video track),
    /// `wg-rtp` (RTP inside the WireGuard tunnel) or `channel`.
    public var videoCarrier = "channel"
    /// Track frames skipped to a keyframe after an unrecoverable loss.
    public var trackFramesDropped: UInt64 = 0
    /// Track packets a NACK brought back.
    public var trackPacketsRecovered: UInt64 = 0

    public init() {}

    /// The carrier name for a frame that came on the media lane (or not)
    /// of a link over `transport`.
    public static func carrier(videoTrack: Bool, transport: TransportKind) -> String {
        guard videoTrack else { return "channel" }
        return transport == .wireGuard ? "wg-rtp" : "track"
    }

    /// The overlay's name for the library's carrier (`webrtc-track`,
    /// `wireguard-udp`, `channel`): a WebRTC track (the link's own, or the
    /// media session's beside a WireGuard link) is `track`.
    public static func carrier(library: String, videoTrack: Bool, transport: TransportKind) -> String {
        switch library {
        case "webrtc-track": "track"
        case "wireguard-udp": "wg-rtp"
        case "channel": "channel"
        default: carrier(videoTrack: videoTrack, transport: transport)
        }
    }
}

/// Where a stream delivers, on a library thread: hand off quickly.
public protocol BrowserStreamSink: AnyObject, Sendable {
    func browserFrame(_ frame: BrowserStreamFrame)
    /// An rb message from the host (`t` = `rb.page`, `rb.screen_applied`, ...)
    /// or an rd control message (`welcome`, `refused`, `ended`), as a JSON object.
    func browserMessage(_ json: Data)
    func browserClosed(code: String, reason: String)
}

/// An open streamed browser tab (cmux-next-ios/verify/browser-stream.md).
public protocol BrowserStreamConnection: AnyObject, Sendable {
    /// An rb control message (a JSON object whose `t` starts with `rb.`).
    func send(message: Data) throws
    /// An rb input event; `mustDeliver` repeats it until acknowledged.
    func send(input: Data, mustDeliver: Bool) throws
    func requestKeyframe()
    func noteDecode(micros: UInt32)
    func stats() -> BrowserStreamStats
    func nowMicros() -> UInt64
    /// The tab is on screen or not: a shown tab keeps the WebRTC media
    /// session beside a WireGuard link open (verify/hybrid-link.md).
    func setVisible(_ visible: Bool)
    func close()
}

extension BrowserStreamConnection {
    public func setVisible(_ visible: Bool) {}
}

/// A link that can stream a Mac browser tab (the `browser` service).
public protocol BrowserStreamOpening: Sendable {
    /// `tab`: the tab's key on the Mac (`s<surface>`); `url`: its first page.
    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection
    /// The shown workspace has browser tabs: open the WebRTC media session
    /// beside a WireGuard link ahead of the first one (no-op otherwise).
    func warmMedia()
    /// Opens a Mac phone tab's simulator (`surface` service, `tab`: `s<surface>`):
    /// the same stream as a browser tab's, from the simulator's framebuffer.
    func openSurface(tab: String, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection
    /// Opens one connection to `port` on the Mac's loopback (`localhost` service,
    /// PROTOCOL.md): a native browser tab's request to `localhost:<port>`.
    func openLocalhost(port: UInt16) async throws -> any LinkChannel
}

extension BrowserStreamOpening {
    public func warmMedia() {}

    public func openSurface(tab: String, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        throw LinkError(code: "no_surface_host", message: "This Mac does not stream simulators")
    }

    public func openLocalhost(port: UInt16) async throws -> any LinkChannel {
        throw LinkError(code: "unknown_service", message: "This Mac does not forward localhost")
    }
}
