import Foundation

/// What `_acpmux/status` says about the daemon's own build and its peers (acpmux `peer.rs`
/// `summary`), for the acpmux peer targets (``AcpmuxPeerUpdateSource``). Unknown fields are ignored.
nonisolated struct AcpmuxPeerUpdateStatus: Sendable, Equatable {
    struct Peer: Sendable, Equatable {
        var name: String
        var url: String
        var connected: Bool
        /// `<hash>[+dirty.x] <date>` of the peer's daemon, nil before its first handshake.
        var remoteBuild: String?

        /// An ssh peer: the only kind `acpmux host update` updates.
        var isSSH: Bool { url.hasPrefix("ssh://") }
    }

    /// `<hash>[+dirty.x] <date>` of the local daemon.
    var build: String?
    /// The daemon's `ACPMUX_HOME`; nil from a daemon that does not report it.
    var home: String?
    var peers: [Peer]

    init(build: String?, home: String? = nil, peers: [Peer]) {
        self.build = build
        self.home = home
        self.peers = peers
    }

    init(_ result: [String: Any]) {
        build = result["build"] as? String
        home = result["home"] as? String
        peers = (result["peers"] as? [[String: Any]] ?? []).compactMap { peer in
            guard let name = peer["name"] as? String, !name.isEmpty else { return nil }
            return Peer(name: name, url: peer["url"] as? String ?? "", connected: peer["connected"] as? Bool ?? false,
                        remoteBuild: peer["remoteBuild"] as? String)
        }
    }

    /// The local daemon's build as ``AcpmuxStatus`` reads it, for its home check.
    var daemon: AcpmuxStatus { AcpmuxStatus(build: build, home: home) }

    /// Why the local daemon may not push its build to peers, nil when it may: it must run the
    /// bundled acpmux (the app's daemon was already handed off to the app's version), from a
    /// clean tree.
    func blocked(bundledBuild: String?) -> String? {
        guard let local = DaemonBuildCommit(build) else { return "local build unknown (\(build ?? "none"))" }
        guard !local.dirty else { return "local build \(build ?? "") has local changes" }
        guard let bundledBuild, build == bundledBuild else {
            return "local daemon runs \(build ?? "?"), not the bundled \(bundledBuild ?? "?")"
        }
        return nil
    }

    /// The peers that are update targets now: connected ssh peers whose names are plain words
    /// (a name is a CLI argument).
    var updatablePeers: [Peer] {
        peers.filter { $0.connected && $0.isSSH && !$0.name.hasPrefix("-") }
    }

    /// `ssh://[user@]host[:port][/...]` -> `host`, lowercased.
    static func host(ofURL url: String) -> String? {
        guard url.hasPrefix("ssh://") else { return nil }
        var rest = url.dropFirst("ssh://".count)
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: rest.startIndex)..<close]
        } else if let colon = rest.firstIndex(of: ":") {
            rest = rest[..<colon]
        }
        return rest.isEmpty ? nil : rest.lowercased()
    }
}
