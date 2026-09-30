public import Foundation

/// acpmux's authenticated loopback WebSocket, split from the dashboard URL
/// the daemon reports (`webUrl`, `http://127.0.0.1:<port>/?token=<t>`).
public nonisolated struct AcpmuxWebEndpoint: Sendable, Equatable {
    /// `ws://` (or `wss://`) URL with the token removed.
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// Nil unless `webURL` is an http(s) URL on a loopback host with a
    /// non-empty `token` query item. The page only ever connects to loopback.
    public init?(webURL: String) {
        guard var components = URLComponents(string: webURL),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, Self.isLoopback(host),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        components.scheme = scheme == "https" ? "wss" : "ws"
        let rest = components.queryItems?.filter { $0.name != "token" } ?? []
        components.queryItems = rest.isEmpty ? nil : rest
        if components.path.isEmpty { components.path = "/" }
        guard let url = components.url else { return nil }
        self.init(url: url, token: token)
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }
}

/// The line `acpmux daemon run --ready-fd <n>` writes once its socket and
/// WebSocket listener are bound:
/// `{"ready":true,"pid":…,"socket":"…","listen":"…","webUrl":"…"}`.
nonisolated struct AcpmuxReadyLine: Decodable, Equatable {
    var ready: Bool
    var pid: Int32?
    var socket: String?
    var webUrl: String?

    static func parse(_ line: String) -> AcpmuxReadyLine? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AcpmuxReadyLine.self, from: data), parsed.ready
        else { return nil }
        return parsed
    }
}
