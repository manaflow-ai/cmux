import Foundation

/// Which transport carries the link. Users switch it in Settings → Connection.
public enum TransportKind: String, CaseIterable, Codable, Sendable {
    case webRTC = "webrtc"
    case wireGuard = "wireguard"

    public var displayName: String {
        switch self {
        case .webRTC: "WebRTC"
        case .wireGuard: "WireGuard"
        }
    }
}

/// How the bytes currently travel.
public enum LinkPathKind: String, Sendable {
    case direct, turn
    /// TURN whose leg to the server is TLS (a network that blocks UDP).
    case turnTLS
    /// No working route at the moment (WireGuard).
    case noPath
}

/// The WebRTC media session beside a WireGuard link, which carries browser
/// video while it works (verify/hybrid-link.md). Links over WebRTC, and Macs
/// without media sessions, stay `off`.
public enum VideoMediaState: Equatable, Sendable {
    /// No session: no browser tab is shown (or this link has none).
    case off
    case connecting
    /// Up over `path`; `rttMillis` is its ICE pair's round trip.
    case up(LinkPathKind, rttMillis: UInt32?)
    /// It failed or dropped: browser video rides the WireGuard tunnel until a retry works.
    case failed(reason: String)

    /// The status line's part ("video WebRTC (TURN)"), nil when there is
    /// nothing to add (video then rides the link itself).
    public var statusLabel: String? {
        switch self {
        case .off, .connecting: nil
        case .up(let path, _): "video WebRTC (\(path == .direct ? "direct" : path.shortName))"
        case .failed: "video in the tunnel"
        }
    }
}

extension LinkPathKind {
    /// "TURN", "TURN over TLS" or "no path".
    var shortName: String {
        switch self {
        case .direct: "direct"
        case .turn: "TURN"
        case .turnTLS: "TURN over TLS"
        case .noPath: "no path"
        }
    }
}

/// Connection state shown in banners and Settings.
public enum LinkState: Equatable, Sendable {
    case idle
    case connecting(TransportKind)
    case connected(TransportKind, LinkPathKind, rttMillis: UInt32?)
    /// The media session beside a WireGuard link changed.
    case media(VideoMediaState)
    case disconnected(reason: String)
}

/// A transport-agnostic connection to one Mac. Implementations: `FFIMacLink`
/// (Rust cmux-mobile-link over WebRTC or WireGuard) and `MockMacLink`.
public protocol MacLink: AnyObject, Sendable {
    var transport: TransportKind { get }
    var states: AsyncStream<LinkState> { get }
    /// Opens a named service channel (`daemon`, `acpmux`, `file`, `echo`).
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel
    /// Opens a channel on the input lane (PROTOCOL.md "Lanes"): terminal
    /// keystrokes and their replies, which then never wait behind bulk
    /// output. A link without one opens an ordinary channel.
    func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel
    func ping() async throws -> UInt32
    /// Whether the link is alive within `timeout`: the round trip on the pong,
    /// nil when other frames from the Mac came first (the pong trails a busy
    /// queue: alive), a throw only when nothing came back at all.
    func probe(timeout: Duration) async throws -> UInt32?
    func close() async
    /// The path of a link that is already up when the dial returns (nil:
    /// unknown until its first `states` element). The controller then adopts
    /// it as connected at once instead of waiting a main-actor turn for the
    /// state stream (verify/perf-latency.md).
    var connectedPath: LinkPathKind? { get }
}

extension MacLink {
    public var connectedPath: LinkPathKind? { nil }

    /// A link that only pings: the pong or nothing.
    public func probe(timeout: Duration) async throws -> UInt32? {
        try await ping()
    }

    public func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try await openChannel(service: service, args: args)
    }
}

/// One multiplexed channel inside a link.
public protocol LinkChannel: AnyObject, Sendable {
    var id: UInt32 { get }
    func send(_ data: Data) async throws
    /// The next message, or nil once the channel is closed.
    func receive() async throws -> Data?
    func close(code: String, reason: String) async
    /// Why the Mac closed the channel, once `receive()` returned nil (nil: unknown).
    var closedBy: LinkError? { get }
}

public extension LinkChannel {
    var closedBy: LinkError? { nil }
}

public struct LinkError: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Everything needed to dial a Mac.
public struct LinkEndpoint: Sendable, Hashable {
    public var baseURL: URL
    public var teamID: String
    public var deviceID: String
    public var macDeviceID: String
    /// Debug "simulate distant network": no direct path. WebRTC and
    /// WireGuard use only TURN (path `turn`, or `turnTLS` when WireGuard's
    /// allocation had to use TLS).
    public var relayOnly: Bool
    /// Debug "simulate a network that blocks UDP": WireGuard rides TURN over
    /// TLS (path `turnTLS`). WebRTC ignores it.
    public var blockUDP: Bool
    /// Debug baseline: do not offer the media lane, so browser video rides
    /// its reliable channel even over WebRTC (verify/browser-video-track.md).
    public var browserVideoOnChannel: Bool

    public init(baseURL: URL, teamID: String, deviceID: String, macDeviceID: String, relayOnly: Bool = false,
                blockUDP: Bool = false, browserVideoOnChannel: Bool = false) {
        self.baseURL = baseURL
        self.teamID = teamID
        self.deviceID = deviceID
        self.macDeviceID = macDeviceID
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
        self.browserVideoOnChannel = browserVideoOnChannel
    }
}

/// Dials a link with a fresh access token for the chosen transport.
public protocol MacLinkDialer: Sendable {
    func dial(_ endpoint: LinkEndpoint, transport: TransportKind, accessToken: String) async throws -> any MacLink
    /// Warms what the next dial in this team needs (signaling socket, ICE
    /// servers) before any Mac is asked for. Returns the steps as
    /// `name=ms` pairs for the timing log.
    func prewarm(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)]
    /// Forgets warm sockets and cached servers (sign-out).
    func resetWarmState() async
    /// The phone's network changed or came back: live links move onto it
    /// without a redial (WireGuard roams; the signaling socket is checked
    /// and replaced when dead). Returns the steps as `name=ms` pairs.
    func networkChanged(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)]
}

extension MacLinkDialer {
    public func prewarm(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] { [] }
    public func resetWarmState() async {}
    public func networkChanged(baseURL: URL, teamID: String, deviceID: String, accessToken: String) async -> [(String, Double)] { [] }
}

/// A link that can measure a simulated network change (DEBUG builds).
public protocol NetworkChangeProbing: MacLink {
    /// Pings for 1 s, takes the network away (and roams at once when
    /// `roam`), keeps pinging for `windowMillis`; returns JSON with the
    /// longest wait for a pong (`stall_ms`) and the roam steps.
    func networkChangeProbe(roam: Bool, windowMillis: UInt32) async -> String
}

/// A dialed link that can say how its dial went (`name`, ms since the dial began).
public protocol TimedMacLink: MacLink {
    var timings: [(String, Double)] { get }
}
