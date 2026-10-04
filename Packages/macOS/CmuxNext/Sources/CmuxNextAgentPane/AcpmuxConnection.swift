public import Foundation

/// What the host's own socket to acpmux needs (``AgentPaneTransport``). It holds both tokens, so it
/// is never encoded, never handed to the page and never logged: its descriptions are redacted.
///
/// - The dashboard token goes in an `Authorization: Bearer` header, never in the URL.
/// - The LocalApp token goes only in the first `initialize` frame (`_meta.acpmux.localAppToken`).
///   It is read from `ACPMUX_HOME/run/localapp.token` at each handshake and reconnect and dropped
///   once that frame is sent; nil when the file is missing or unreadable, so the pane connects
///   as remote-origin.
public nonisolated struct AcpmuxConnection: Sendable, Equatable {
    /// The origin the daemon accepts for the bundled pane (`server/local_app.rs`).
    public static let paneOrigin = "cmux-agent://pane"

    /// `ws://127.0.0.1:<port>/`, without a token.
    public var url: URL
    public var dashboardToken: String
    public var localAppToken: String?

    public init(url: URL, dashboardToken: String, localAppToken: String?) {
        self.url = url
        self.dashboardToken = dashboardToken
        self.localAppToken = localAppToken
    }

    /// The daemon's endpoint and this launch's LocalApp token, read now from `home`.
    public init(endpoint: AcpmuxWebEndpoint, home: URL?) {
        self.init(url: endpoint.url, dashboardToken: endpoint.token,
                  localAppToken: home.flatMap(AcpmuxLocalAppToken.read(home:)))
    }

    /// The upgrade request: bearer token and the pane's Origin.
    var request: URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(dashboardToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.paneOrigin, forHTTPHeaderField: "Origin")
        return request
    }
}

extension AcpmuxConnection: CustomStringConvertible, CustomDebugStringConvertible {
    public nonisolated var description: String {
        "AcpmuxConnection(\(url.absoluteString), localApp: \(localAppToken == nil ? "none" : "redacted"))"
    }

    public nonisolated var debugDescription: String { description }
}

/// The daemon's per-launch LocalApp token file (acpmux `server/local_app.rs` `token_path`).
public nonisolated enum AcpmuxLocalAppToken {
    /// `home/run/localapp.token`.
    public static func path(home: URL) -> URL {
        home.appendingPathComponent("run", isDirectory: true).appendingPathComponent("localapp.token")
    }

    /// The token (64 lowercase hex characters, whitespace trimmed), or nil when the file is
    /// missing, unreadable or malformed. Never cached; never logged. Runs on the caller's
    /// executor: callers are off the main actor (``AcpmuxHost`` is an actor).
    public static func read(home: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: path(home: home).path), data.count <= 256 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return text
    }
}
