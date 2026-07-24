import Foundation

/// Persisted state shared by every Bonsplit-backed session container.
///
/// Workspaces embed their main split state directly in `SessionWorkspaceSnapshot` for
/// historical compatibility. Docks use this envelope so their layout and their existing
/// terminal/browser panel codecs travel together as one optional restore unit.
struct SessionSplitContainerSnapshot: Codable, Sendable {
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    var panels: [SessionPanelSnapshot]
    /// Original workspace ownership for panels transferred into this container.
    /// Absent for panels created directly in the container and for legacy snapshots.
    var sourceWorkspaceIdsByPanelId: [UUID: UUID]? = nil
}
