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
    /// cmux's own WebSocket relay over HTTPS (WireGuard): neither UDP nor
    /// the TURN host gets through (PROTOCOL.md "WebSocket relay").
    case httpsRelay
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
        case .httpsRelay: "cmux relay"
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
    /// The link heard nothing for `silentMillis` after a ping (Rust
    /// `Link::suspect_state`). Still open; the next `connected` says it
    /// answered again. Only `disconnected` ends it.
    case suspect(silentMillis: UInt32)
}

/// A transport-agnostic connection to one Mac. Implementations: `FFIMacLink`
/// (Rust cmux-mobile-link over WebRTC or WireGuard) and `MockMacLink`.
public protocol MacLink: AnyObject, Sendable {
    var transport: TransportKind { get }
    var states: AsyncStream<LinkState> { get }
    /// Opens a named service channel (`daemon`, `acpmux`, `file`, `echo`).
    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel
    /// Opens a service channel whose open args are any JSON object (`catch-up` takes nested
    /// cursors). A link without its own sends flat string args only.
    func openChannel(service: String, argsJSON: String) async throws -> any LinkChannel
    /// Opens a channel on the input lane (PROTOCOL.md "Lanes"): terminal
    /// keystrokes and their replies, which then never wait behind bulk
    /// output. A link without one opens an ordinary channel.
    func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel
    func ping() async throws -> UInt32
    /// Whether the link is alive within `timeout`: the round trip on the pong,
    /// nil when other frames from the Mac came first (the pong trails a busy
    /// queue: alive), a throw only when nothing came back at all.
    func probe(timeout: Duration) async throws -> UInt32?
    /// How long a probe of this link may wait for its pong: `floor`, or
    /// longer on a link whose measured round trip needs it (the Rust link:
    /// three smoothed round trips, at most 5 s).
    func probeTimeout(floor: Duration) -> Duration
    /// The app is in the foreground with a terminal or chat on screen, or
    /// not. The Rust link probes more often while it is (every 3 s on its
    /// datagram lane); a link without one ignores it.
    func setForegroundProbe(_ on: Bool)
    /// The person is about to type (the keyboard is coming up): wake the
    /// phone's radio with one tiny datagram so the first key does not pay
    /// the LTE/5G idle-to-connected promotion (RFD 0142 hypothesis 2). The
    /// Rust link sends at most one per second, and only on a quiet link.
    func prewake()
    func close() async
    /// The path of a link that is already up when the dial returns (nil:
    /// unknown until its first `states` element). The controller then adopts
    /// it as connected at once instead of waiting a main-actor turn for the
    /// state stream (verify/perf-latency.md).
    var connectedPath: LinkPathKind? { get }
    /// Where a direct path's peer address is, as the Rust link names it
    /// (`cmux_mobile_link::dial::peer_scope`): `lan`, `tailnet` (a Tailscale or
    /// CGNAT address), `wan`, or empty on a relayed path, before a route, or
    /// when the link cannot say. The DEBUG hand-off receipt names it.
    var peerScope: String { get }
    /// How long ago the link last received any frame from the Mac (a pong,
    /// channel data, a control frame), measured where frames arrive, not where
    /// a channel's reader takes them; nil when the link cannot say. Any frame
    /// proves the link alive as a probe would, so the heartbeat probes only a
    /// link this long quiet.
    var receivedAgo: Duration? { get }
    /// How long ago the link last received a frame other than a ping or a
    /// pong; nil when the link cannot say. A link with no traffic for a beat
    /// is idle: with Align Keepalives on, the heartbeat probes it on the
    /// keepalive beat (``KeepaliveBeat``).
    var trafficAgo: Duration? { get }
    /// The WireGuard static public keys this link's tunnel handshook with
    /// (nil: not a tunnel). The phone's `auth` signs them and checks the Mac's
    /// identity proof over them (``TunnelKeys``).
    var tunnelKeys: TunnelKeys? { get }
}

/// The two WireGuard static public keys of a tunnel (base64, as in `wg-init`
/// and `wg-resp`): the dialer's (this phone's) and the answerer's (the Mac's).
/// A v2 `auth`'s identity proofs cover them (cmux-mobile-host `pairing.rs`).
public struct TunnelKeys: Sendable, Equatable {
    public var dialer: String
    public var answerer: String

    public init(dialer: String, answerer: String) {
        self.dialer = dialer
        self.answerer = answerer
    }
}

extension MacLink {
    public func openChannel(service: String, argsJSON: String) async throws -> any LinkChannel {
        let object = try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))
        guard let args = object as? [String: String] else {
            throw LinkError(code: "bad_request", message: "this link sends flat string args only")
        }
        return try await openChannel(service: service, args: args)
    }
    public var connectedPath: LinkPathKind? { nil }
    public var peerScope: String { "" }
    public var receivedAgo: Duration? { nil }
    public var trafficAgo: Duration? { nil }
    public var tunnelKeys: TunnelKeys? { nil }
    public func probeTimeout(floor: Duration) -> Duration { floor }
    public func setForegroundProbe(_ on: Bool) {}
    public func prewake() {}

    /// A link that only pings: the pong or nothing.
    public func probe(timeout: Duration) async throws -> UInt32? {
        try await ping()
    }

    public func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try await openChannel(service: service, args: args)
    }
}

/// A link the Mac can hold while the app is suspended (PROTOCOL.md "Parked
/// link"): a WireGuard link to a Mac that knows parking.
public protocol ParkableMacLink: MacLink {
    /// Before the OS suspends the app: ask the Mac to hold the link for up to
    /// `hold` while the phone is silent. `true`: parked, and nothing on the
    /// link wakes the phone until ``resumeParked()``. `false`: an older Mac,
    /// no answer within `timeout`, or a transport that cannot be held.
    func park(hold: Duration, timeout: Duration) async -> Bool
    /// Back in front: `true` when the link was parked and its hold has not
    /// passed. The tunnel then moves onto a fresh socket; probe it, and the
    /// first frame back ends the park on both sides.
    func resumeParked() -> Bool
    /// In front again, how long the resumed link may stay silent before a
    /// redial is raced against it (the Rust link: three smoothed round trips
    /// plus 100 ms, within 250 ms and 1.5 s); nil keeps the controller's own.
    var resumeHedge: Duration? { get }
}

public extension ParkableMacLink {
    var resumeHedge: Duration? { nil }
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
    /// Payload bytes the link has taken from this channel so far; it moves while a long write
    /// drains and stops when the link stalls (nil: not known). ``DaemonClient/submit`` reads it
    /// as progress.
    var sentBytes: UInt64? { get }
}

public extension LinkChannel {
    var closedBy: LinkError? { nil }
    var sentBytes: UInt64? { nil }
}

public struct LinkError: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    /// The code for the cmux service refusing the access token (a 401), as the
    /// Rust link sends it (`cmux_mobile_link_ffi::UNAUTHORIZED`).
    public static let unauthorized = "unauthorized"
    /// The code for a dial that found no way to the Mac, each way's failure
    /// known (`cmux_mobile_link_ffi::NETWORK_BLOCKED`); the message is the
    /// record as JSON (``NetworkBlock``).
    public static let networkBlocked = "network_blocked"

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// What a person reads for a link error: never the code or the type.
extension LinkError: LocalizedError {
    /// The codes with fixed copy: a fragment for status lines ("WebRTC failed: …")
    /// and a sentence for alerts and failure states. None asks the person to repeat the step: the link
    /// redials on its own (backoff, the Mac's signal, foreground), so allowing the iPhone or
    /// opening cmux on the Mac is noticed without the person repeating anything.
    private var known: (reason: String, sentence: String)? {
        switch code {
        case _ where isTimeout:
            return (reason: LinkError.timeoutReason, sentence: LinkError.timeoutSentence)
        case "not_admitted":
            return (reason: "the Mac refused this phone",
                    sentence: "Your Mac didn't allow this iPhone. Allow it on your Mac.")
        case "offline":
            return (reason: "the Mac is offline", sentence: "Your Mac isn't connected. Open cmux on your Mac.")
        case LinkError.unauthorized:
            return (reason: "the cmux service refused the request", sentence: "Your session expired. Sign in again.")
        case LinkError.networkBlocked:
            let block = NetworkBlock(json: message)
            return (reason: block.reason, sentence: block.sentence)
        default:
            return nil
        }
    }

    /// A request or write that ran out of time (the link's, the daemon's or acpmux's deadline).
    /// Its raw message is a diagnostic; a person reads only the fixed, calm copy below, which
    /// says what to do (Leo 2026-11-21: no "didn't answer in time").
    public var isTimeout: Bool { ["timeout", "reply_timeout", "write_timeout"].contains(code) }
    /// The link is coming back on its own (a timeout, a dropped or not-yet-open link): nothing
    /// for a person to do or read. A call that failed this way waits for the link and goes again
    /// (Leo 2026-11-22: "i dont wanna see reconnecting to the Mac in a toast, i want it to just
    /// connect").
    public var isTransient: Bool {
        isTimeout || ["closed", "offline", "eof", "transport", "signaling"].contains(code)
    }
    /// A status line's fragment for a timeout: the connection is being re-established.
    public static let timeoutReason = "reconnecting to the Mac"
    /// A failure state's sentence for a timeout that outlasted the quiet retries.
    public static let timeoutSentence = "Can't reach your Mac right now. Make sure it's awake and cmux is open."

    /// The Mac's or the link's own message, when it reads as a sentence for a person (never
    /// for a timeout: that message is a diagnostic).
    private var proseMessage: String? {
        guard !isTimeout else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 240, text.contains(" "), let first = text.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return nil }
        let markers = ["{", "}", "<", ">", "_", "://", "Error(", "(code:", "couldn’t be completed", "couldn't be completed"]
        return markers.contains(where: { text.contains($0) }) ? nil : text
    }

    /// A short, display-safe fragment for a status line (lower case, no period).
    public var displayReason: String {
        if let known { return known.reason }
        return proseMessage.map { String($0.prefix(80)) } ?? "the connection to the Mac failed"
    }

    /// A sentence: the Mac's own message when it is prose, else the code's copy.
    public var errorDescription: String? {
        if code == LinkError.unauthorized { return known?.sentence }
        return proseMessage ?? known?.sentence ?? "Something went wrong talking to your Mac."
    }
}

/// Why a WireGuard dial found no way to the Mac (PROTOCOL.md "When no path
/// works"): what plain UDP, TURN and cmux's relay each did, from the record
/// the Rust link returns (`network_blocked`). The person reads one line
/// they can act on: another network, an update on the Mac, or what IT must
/// allow, with the hosts named.
public struct NetworkBlock: Equatable, Sendable, Decodable {
    public var udp: String?
    public var turn: String?
    public var turnHost: String?
    public var relay: String?
    public var relayHost: String?
    public var relayStatus: Int?
    public var relayDetail: String?

    public init(udp: String? = nil, turn: String? = nil, turnHost: String? = nil, relay: String? = nil,
                relayHost: String? = nil, relayStatus: Int? = nil, relayDetail: String? = nil) {
        self.udp = udp
        self.turn = turn
        self.turnHost = turnHost
        self.relay = relay
        self.relayHost = relayHost
        self.relayStatus = relayStatus
        self.relayDetail = relayDetail
    }

    /// The record in `json`; an unreadable one reads as "everything blocked".
    public init(json: String) {
        self = (try? JSONDecoder().decode(NetworkBlock.self, from: Data(json.utf8))) ?? NetworkBlock()
    }

    /// What blocks the link, which decides what the person can do.
    public enum Cause: Equatable, Sendable {
        /// The Mac's cmux has no relay: update it.
        case macNeedsUpdate
        /// A proxy re-signs TLS (inspection): IT must exempt cmux's hosts.
        case tlsInspection
        /// The relay is turned off for now: another network.
        case relayPaused
        /// Something on the network refused the relay's request (an HTTP status).
        case refused(status: Int?)
        /// Nothing answered at all: another network, or IT allows the hosts.
        case blocked
    }

    public var cause: Cause {
        switch relay {
        case "peer_cannot": .macNeedsUpdate
        case "tls_rejected": .tlsInspection
        case "off": .relayPaused
        case "refused": .refused(status: relayStatus)
        default: .blocked
        }
    }

    private var hosts: String {
        let names = [relayHost ?? "mobile-api.cmux.dev", turnHost ?? "turn.cloudflare.com"]
        return names.joined(separator: " and ")
    }

    /// A status-line fragment (lower case, no period).
    public var reason: String {
        switch cause {
        case .macNeedsUpdate: "this network needs a newer cmux on your Mac"
        case .tlsInspection: "this network's proxy blocks cmux"
        case .relayPaused, .refused, .blocked: "this network blocks cmux"
        }
    }

    /// The section header's line: what blocks it and the one thing to do.
    public var statusLine: String {
        switch cause {
        case .macNeedsUpdate: "Update cmux on your Mac to connect on this network"
        case .tlsInspection: "This network's proxy blocks cmux · Ask IT to allow it"
        case .relayPaused, .refused, .blocked: "This network blocks cmux · Try another network"
        }
    }

    /// The full sentence for alerts and the connection details, with the hosts.
    public var sentence: String {
        switch cause {
        case .macNeedsUpdate:
            "This network blocks direct and TURN connections to your Mac. Update cmux on your Mac so it can use the cmux relay, or try another network."
        case .tlsInspection:
            "A proxy on this network intercepts cmux's secure connections. Ask your IT team to exempt \(hosts) from TLS inspection, or try another network."
        case .relayPaused:
            "This network blocks direct and TURN connections, and the cmux relay is paused right now. Try another network, such as cellular."
        case .refused(let status):
            "This network refused the cmux relay\(status.map { " (HTTP \($0))" } ?? ""). Ask your IT team to allow \(relayHost ?? "mobile-api.cmux.dev") on port 443, or try another network."
        case .blocked:
            "This network blocks every way cmux reaches your Mac: UDP, \(turnHost ?? "turn.cloudflare.com") and \(relayHost ?? "mobile-api.cmux.dev"). Try another network, or ask your IT team to allow them (cmux.com/docs/nightly/next/network-requirements)."
        }
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
    /// Debug "Relay via cmux (HTTPS) only": WireGuard rides cmux's WebSocket
    /// relay alone (path `httpsRelay`). WebRTC ignores it.
    public var forceRelay: Bool = false
    /// Debug "simulate a network whose only way out is its proxy": WireGuard
    /// rides TURN over TLS through the system's proxy, or fails saying there
    /// is none. WebRTC ignores it.
    public var proxyOnly: Bool
    /// Debug "simulate a firewall that drops WireGuard": WireGuard falls
    /// through to TURN over TLS (path `turnTLS`). WebRTC ignores it.
    public var dropWireGuard: Bool
    /// Debug baseline: do not offer the media lane, so browser video rides
    /// its reliable channel even over WebRTC (verify/browser-video-track.md).
    public var browserVideoOnChannel: Bool

    public init(baseURL: URL, teamID: String, deviceID: String, macDeviceID: String, relayOnly: Bool = false,
                blockUDP: Bool = false, proxyOnly: Bool = false, dropWireGuard: Bool = false,
                browserVideoOnChannel: Bool = false) {
        self.baseURL = baseURL
        self.teamID = teamID
        self.deviceID = deviceID
        self.macDeviceID = macDeviceID
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
        self.proxyOnly = proxyOnly
        self.dropWireGuard = dropWireGuard
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
