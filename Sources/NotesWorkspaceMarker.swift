import Foundation

/// Contents of a per-workspace `_workspace.json` marker. The notes folder is
/// keyed by the workspace's persistent note anchor (`Workspace.noteAnchorId`,
/// saved/restored with the session) so each workspace gets its own folder even
/// when several workspaces share a working directory; pre-anchor folders are
/// adopted by `cwd` match and stamped with the anchor on first write.
struct NotesWorkspaceMarker: Codable, Equatable, Sendable {
    /// Human-friendly workspace title, kept fresh for display/browsing.
    var title: String
    /// The workspace's working directory (standardized); display + legacy
    /// binding fallback.
    var cwd: String
    /// The workspace's persistent note anchor id — the binding key. Optional
    /// for markers written before anchor keying existed.
    var anchorId: String?
    /// Agent sessions observed running in this workspace's panes, accrued
    /// over time so the Notes tab lists THIS workspace's sessions rather than
    /// every session sharing the directory.
    var sessions: [NotesWorkspaceSessionRecord]?
}
