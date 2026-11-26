import Foundation
import Security

/// What a viewer needs to reach a host over WebRTC: the signaling Worker,
/// the room, and the room secret. Shared as
/// `cmux-vnc://pair?signal=<url>&room=<hex>&secret=<token>&name=<label>`.
public struct VNCPairing: Sendable, Hashable, Codable {
    public var signal: URL
    public var room: String
    public var secret: String
    public var name: String
    /// `vnc`: RFB bytes over a data channel. `stream`: the screen as a WebRTC
    /// video track with input on a data channel (`ScreenStreamHost`).
    public var kind: String = "vnc"

    /// A constant https literal, so it always parses; /dev/null only stands in for the type checker.
    public static let defaultSignal = URL(string: "https://cmux-vnc-signal.debussy.workers.dev") ?? URL(fileURLWithPath: "/dev/null")

    public init(signal: URL, room: String, secret: String, name: String, kind: String = "vnc") {
        self.signal = signal
        self.room = room
        self.secret = secret
        self.name = name
        self.kind = kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signal = try container.decode(URL.self, forKey: .signal)
        room = try container.decode(String.self, forKey: .room)
        secret = try container.decode(String.self, forKey: .secret)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "vnc"
    }

    public var isStream: Bool { kind == "stream" }

    /// A new room (128-bit id) and secret (256-bit) on `signal`.
    public static func generate(name: String, signal: URL = defaultSignal, kind: String = "vnc") -> VNCPairing {
        VNCPairing(signal: signal, room: random(16).map { String(format: "%02x", $0) }.joined(),
                   secret: Data(random(32)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                       .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
                   name: name, kind: kind)
    }

    public var link: URL {
        var components = URLComponents()
        components.scheme = "cmux-vnc"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "signal", value: signal.absoluteString),
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "kind", value: kind),
        ]
        // A scheme, a host and query items always form a URL; /dev/null only stands in for the type checker.
        return components.url ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Parses a pairing link; nil for anything else.
    public init?(link: URL) {
        guard link.scheme == "cmux-vnc", link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let raw = value("signal"), let signal = URL(string: raw), signal.scheme == "https",
              let room = value("room"), room.count == 32, room.allSatisfy(\.isHexDigit),
              let secret = value("secret"), (32 ... 128).contains(secret.count) else { return nil }
        self.init(signal: signal, room: room, secret: secret, name: value("name") ?? "Mac",
                  kind: value("kind") == "stream" ? "stream" : "vnc")
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let base = signal.appendingPathComponent("v1/rooms/\(room)/\(path)")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        if !query.isEmpty { components.queryItems = query }
        return components.url ?? base
    }

    private static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}
