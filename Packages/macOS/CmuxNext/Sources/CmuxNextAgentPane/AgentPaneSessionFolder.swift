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
        self.init(entry: entry, cwd: cwd)
    }

    /// The same folder decision for `_acpmux/info`, whose result is one
    /// session detail rather than a `sessions` array.
    init?(sessionId: String, info: [String: Any]) {
        guard info["sessionId"] as? String == sessionId,
              let cwd = info["cwd"] as? String, !cwd.isEmpty else { return nil }
        self.init(entry: info, cwd: cwd, exactSummary: true)
    }

    private init(entry: [String: Any], cwd: String, exactSummary: Bool = false) {
        if exactSummary {
            // Exact reads return the daemon's summary: local rows have no
            // `peer`, while mirrored rows retain their peer name. Do not infer
            // locality from a display-only host field.
            let peer = entry["peer"] as? String
            self.init(cwd: cwd, isLocal: peer == nil || peer?.isEmpty == true)
            return
        }
        let hostKind = entry["hostKind"] as? String
        let named = { (key: String) in entry[key].map { !($0 is NSNull) && ($0 as? Bool) != false && ($0 as? String) != "" } ?? false }
        self.init(cwd: cwd, isLocal: hostKind == "local" || (hostKind == nil && !named("host") && !named("peer")))
    }
}
