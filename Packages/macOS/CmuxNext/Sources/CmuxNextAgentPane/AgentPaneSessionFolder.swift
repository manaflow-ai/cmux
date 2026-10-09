import Foundation

/// Where an acpmux session works: its folder, and whether that folder is
/// on this Mac. The host reads it from the daemon for the pane's own
/// session, so a commit or push never runs in a folder the page named.
public nonisolated struct AgentPaneSessionFolder: Equatable, Sendable {
    public var cwd: String
    /// False for a session on another machine (a cloud host, a peer, or any
    /// host other than this Mac's daemon): its folder is not this Mac's.
    public var isLocal: Bool

    public init(cwd: String, isLocal: Bool) {
        self.cwd = cwd
        self.isLocal = isLocal
    }

    /// The entry for `sessionId` in a `_acpmux/watch` session list, nil when
    /// it is missing or names no folder.
    init?(sessionId: String, in sessions: Any?) {
        guard let entries = sessions as? [[String: Any]],
              let entry = entries.first(where: { $0["sessionId"] as? String == sessionId }),
              let cwd = entry["cwd"] as? String, !cwd.isEmpty else { return nil }
        let hostKind = entry["hostKind"] as? String
        let peer = entry["peer"].map { !($0 is NSNull) && ($0 as? Bool) != false } ?? false
        self.init(cwd: cwd, isLocal: (hostKind == nil || hostKind == "local") && !peer)
    }
}
