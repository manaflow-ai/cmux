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

    /// Parses a `servers.json` payload. Returns an empty selection for a
    /// missing/unset default, and `nil` for undecodable data (callers fall
    /// back to the local daemon either way).
    public init?(serversJSON data: Data) {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let name: String
                let url: String
            }

            let servers: [Entry]?
            let `default`: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        guard
            let defaultName = payload.default?.trimmingCharacters(in: .whitespacesAndNewlines),
            !defaultName.isEmpty,
            let entry = payload.servers?.first(where: { $0.name == defaultName }),
            let endpoint = SubrouterEndpoint(configurationString: entry.url)
        else {
            self.init(defaultServer: nil)
            return
        }
        self.init(defaultServer: Server(name: defaultName, endpoint: endpoint))
    }
}
