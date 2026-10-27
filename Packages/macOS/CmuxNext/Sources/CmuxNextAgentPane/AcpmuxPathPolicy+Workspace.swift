import Foundation

/// The workspace a pane's new chat belongs to. acpmux records a chat's workspace only when it is
/// created (`_meta.acpmux.workspaceId` on `session/new`), then reads it for the workspace's
/// sub-session limit (`_acpmux/subsession/limits {workspaceId}`) and, in per-workspace display
/// mode, for the chat's computer use display. The page never names it: the params rule (P1)
/// refuses the key from the page, and the host writes its own value over anything there.
nonisolated extension AcpmuxPathPolicy {
    /// The `_meta.acpmux` key acpmux reads the workspace from (`session_env::workspace_id`).
    static let workspaceIDKey = "workspaceId"

    /// Puts the pane's workspace into a local `session/new`'s `_meta.acpmux`, over any value
    /// already there. A start on a peer (a non-empty `peer`, as acpmux reads it) and a pane with
    /// no workspace key get none, and lose any value already there: a peer's workspaces are not
    /// this Mac's. Whether `acpmux` changed.
    static func stampWorkspace(_ acpmux: inout [String: Any]?, id: String?) -> Bool {
        let peer = (acpmux?["peer"] as? String).map { !$0.isEmpty } ?? false
        let removed = acpmux?.removeValue(forKey: workspaceIDKey) != nil
        guard !peer, let key = id.flatMap(workspaceKey) else { return removed }
        var fields = acpmux ?? [:]
        fields[workspaceIDKey] = key
        acpmux = fields
        return true
    }

    /// `id` as acpmux stores a workspace (`session_env::is_workspace_id`, kept lowercase): a
    /// dashed UUID of ASCII hex digits, lowercased; nil for any other key (a `handle:` stand-in, a
    /// legacy key), which acpmux would refuse (`workspace.value_refused`).
    static func workspaceKey(_ id: String) -> String? {
        let groups = id.utf8.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
        let hex: (UInt8) -> Bool = { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
        guard groups.count == 5, zip(groups, [8, 4, 4, 4, 12]).allSatisfy({ $0.count == $1 && $0.allSatisfy(hex) }) else { return nil }
        return id.lowercased()
    }
}
