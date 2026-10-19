import Foundation

/// Where a viewer finds a screen stream host and its signaling
/// (plans/cmux-next/remote-desktop-v2.md, "Viewer"). Both kinds carry the
/// same `SignalMessage`s, so one state machine runs on both.
public enum ScreenEndpoint: Sendable, Hashable {
    /// The signal Worker's room, from a pairing link (room + secret). The
    /// fallback for a viewer with no tailnet.
    case room(VNCPairing)
    /// The host's own tailnet signaling port. No secret: the host names the
    /// device with Tailscale WhoIs and checks its access list.
    case tailnet(TailnetScreenTarget)

    /// The host's display name.
    public var name: String {
        switch self {
        case let .room(pairing): pairing.name
        case let .tailnet(target): target.name
        }
    }
}

/// A screen host on the user's tailnet.
public struct TailnetScreenTarget: Sendable, Hashable, Codable {
    /// The host's tailnet signaling port (`cmux-screen-host`, tailnet_signal.rs).
    public static let defaultPort: UInt16 = 4180

    public var name: String
    /// The host's MagicDNS name, for example `cmux-studio.example.ts.net`.
    public var host: String
    public var port: UInt16
    /// How this device reaches `host:port`.
    public var route: TailnetRoute
    /// A room for the host's fallback ICE servers, used when the host sends
    /// no `ice` message before its `hello`. Nil: no ICE servers (host
    /// candidates only, which is enough when both ends have system Tailscale).
    public var fallbackRoom: VNCPairing?

    public init(name: String, host: String, port: UInt16 = TailnetScreenTarget.defaultPort,
                route: TailnetRoute = .daemonForward, fallbackRoom: VNCPairing? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.route = route
        self.fallbackRoom = fallbackRoom
    }

    /// `host:port`, the target of the daemon's `tailnet.forward`.
    public var forwardTarget: String { "\(host):\(port)" }
}

/// How a viewer reaches a tailnet address. The app does not embed Tailscale.
public enum TailnetRoute: String, Sendable, Hashable, Codable {
    /// Through the cmux-next daemon's tailnet node: `tailnet.forward
    /// {target}` returns a local endpoint that the daemon forwards.
    case daemonForward
    /// Straight to the MagicDNS name, through the system Tailscale app's
    /// interface (only on a device where it is installed and connected).
    case systemTailscale
}

/// A local endpoint that the daemon forwards to a tailnet address.
public enum TailnetLocalEndpoint: Sendable, Hashable {
    /// A loopback TCP port (`127.0.0.1` or `::1`).
    case tcp(host: String, port: UInt16)
    /// A Unix domain socket.
    case unix(path: String)
}

extension TailnetLocalEndpoint: Decodable {
    private enum CodingKeys: String, CodingKey { case tcp, unix }

    /// The daemon's `tailnet.forward` result: `{"tcp":"127.0.0.1:PORT"}` or
    /// `{"unix":"/path/to/socket"}`. A TCP address must be loopback: the
    /// forward is for this device only.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .unix) {
            guard path.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(forKey: .unix, in: container, debugDescription: "not an absolute path")
            }
            self = .unix(path: path)
            return
        }
        let address = try container.decode(String.self, forKey: .tcp)
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]), port > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .tcp, in: container, debugDescription: "not host:port")
        }
        var host = String(address[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard host == "127.0.0.1" || host == "::1" || host == "localhost" else {
            throw DecodingError.dataCorruptedError(forKey: .tcp, in: container, debugDescription: "not a loopback address")
        }
        self = .tcp(host: host, port: port)
    }
}

/// The app's bridge to the daemon's tailnet node (`tailnet.forward`). The
/// screen packages do not talk to the daemon; the app passes this in.
public protocol TailnetForwarding: Sendable {
    /// A local endpoint that reaches `target` (`host:port`) over the tailnet.
    func forward(target: String) async throws -> TailnetLocalEndpoint
}

/// Why a tailnet signaling link did not open or ended. The app maps each
/// case to its own localized text.
public enum TailnetSignalError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `.daemonForward` without a `TailnetForwarding` (no daemon connection).
    case noForwarding
    /// The daemon could not forward to the host (not signed in, host offline).
    case forwardFailed(String)
    /// The connection or the WebSocket handshake failed. The host refuses a
    /// device that its access list does not allow.
    case unreachable(String)
    /// The host closed the link before the stream opened.
    case closed

    public var description: String {
        switch self {
        case .noForwarding: "tailnet: no daemon forward"
        case let .forwardFailed(detail): "tailnet forward: \(detail)"
        case let .unreachable(detail): "tailnet signaling: \(detail)"
        case .closed: "tailnet signaling closed"
        }
    }
}
