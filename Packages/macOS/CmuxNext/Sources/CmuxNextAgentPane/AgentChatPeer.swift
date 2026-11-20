import Foundation

/// The Environment picker's peer inventory: `_acpmux/status`, without URLs or credentials.
public nonisolated struct AgentChatPeer: Sendable, Equatable {
    public let name: String
    public let isSSH: Bool
    public let connected: Bool?
    public let state: String?

    public init(name: String, isSSH: Bool, connected: Bool?, state: String?) {
        (self.name, self.isSSH, self.connected, self.state) = (name, isSSH, connected, state)
    }

    /// Matches environments.ts environmentReady: a state takes precedence over the old flag.
    public var isReady: Bool { state.map { $0 == "connected" } ?? (connected != false) }

    static func read(_ status: [String: Any]) -> [Self] {
        (status["peers"] as? [[String: Any]] ?? []).compactMap { peer in
            guard let name = peer["name"] as? String, !name.isEmpty, name != "local" else { return nil }
            let ssh = (peer["transport"] as? String).map { $0 == "ssh" }
                ?? (peer["url"] as? String ?? "").hasPrefix("ssh://")
            return Self(name: name, isSSH: ssh, connected: peer["connected"] as? Bool,
                        state: (peer["state"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
