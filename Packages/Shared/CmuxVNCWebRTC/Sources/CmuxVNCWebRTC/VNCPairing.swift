import Foundation
import Security

/// What a viewer needs to reach a host over WebRTC: the signaling Worker,
/// the room, and the room secret. Shared as
/// `cmux-vnc://pair?signal=<url>&room=<hex>&secret=<token>&name=<label>`.
public struct VNCPairing: Sendable, Equatable, Codable {
    public var signal: URL
    public var room: String
    public var secret: String
    public var name: String

    public static let defaultSignal = URL(string: "https://cmux-vnc-signal.debussy.workers.dev")!

    public init(signal: URL, room: String, secret: String, name: String) {
        self.signal = signal
        self.room = room
        self.secret = secret
        self.name = name
    }

    /// A new room (128-bit id) and secret (256-bit) on `signal`.
    public static func generate(name: String, signal: URL = defaultSignal) -> VNCPairing {
        VNCPairing(signal: signal, room: random(16).map { String(format: "%02x", $0) }.joined(),
                   secret: Data(random(32)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                       .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
                   name: name)
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
        ]
        return components.url!
    }

    /// Parses a pairing link; nil for anything else.
    public init?(link: URL) {
        guard link.scheme == "cmux-vnc", link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let raw = value("signal"), let signal = URL(string: raw), signal.scheme == "https",
              let room = value("room"), room.count == 32, room.allSatisfy(\.isHexDigit),
              let secret = value("secret"), (32 ... 128).contains(secret.count) else { return nil }
        self.init(signal: signal, room: room, secret: secret, name: value("name") ?? "Mac")
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: signal.appendingPathComponent("v1/rooms/\(room)/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}
