public import Foundation

/// The `sr` CLI's server registry (`~/.subrouter/codex/servers.json`): named
/// daemon URLs plus an optional default selection.
///
/// cmux resolves its polling endpoint the same way `sr` resolves its target
/// server, so the panel always shows the daemon that is actually routing
/// this machine's agents. When the default server is remote, account
/// selection happens per session on the server and `sr switch` refuses to
/// edit local state — callers use ``defaultServer`` to detect that mode.
public struct SubrouterServerSelection: Sendable, Equatable {
    /// One named server entry.
    public struct Server: Sendable, Equatable {
        /// The `sr server` name, e.g. `cmux-mac-mini`.
        public let name: String
        /// The daemon endpoint parsed from the registry URL.
        public let endpoint: SubrouterEndpoint

        /// Creates an entry.
        public init(name: String, endpoint: SubrouterEndpoint) {
            self.name = name
            self.endpoint = endpoint
        }
    }

    /// The default server, or `nil` when `sr` targets the local daemon.
    public let defaultServer: Server?

    /// Creates a selection.
    public init(defaultServer: Server?) {
        self.defaultServer = defaultServer
    }

    /// Parses a `servers.json` payload.
    ///
    /// An absent or empty `default` is a legitimate local-daemon selection.
    /// Undecodable data returns `nil` — and so does a `default` naming a
    /// missing entry or one whose URL does not parse: a partially written
    /// or inconsistent registry that still names a server must read as
    /// unreadable (fail closed), never silently select the local daemon
    /// where a switch would mutate the wrong credentials.
    public init?(serversJSON data: Data) {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let name: String
                let url: String
                // `sr server add --admin-token`: required by non-loopback
                // `/_subrouter/*` endpoints when the server configures one.
                let adminToken: String?
            }

            let servers: [Entry]?
            let `default`: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        guard
            let defaultName = payload.default?.trimmingCharacters(in: .whitespacesAndNewlines),
            !defaultName.isEmpty
        else {
            self.init(defaultServer: nil)
            return
        }
        guard
            let entry = payload.servers?.first(where: { $0.name == defaultName }),
            let parsed = SubrouterEndpoint(configurationString: entry.url)
        else {
            return nil
        }
        let token = entry.adminToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = SubrouterEndpoint(
            baseURL: parsed.baseURL,
            adminToken: (token?.isEmpty ?? true) ? nil : token
        )
        self.init(defaultServer: Server(name: defaultName, endpoint: endpoint))
    }
}
