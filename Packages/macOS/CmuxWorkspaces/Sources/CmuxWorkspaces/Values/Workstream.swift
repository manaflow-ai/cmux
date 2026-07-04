public import Foundation

/// A top-level, drill-in "workstream": a first-class initiative/epic that owns
/// a set of PR-workspaces. Workstreams sit a level ABOVE the inline
/// `WorkspaceGroup` disclosure — the sidebar shows the short list of
/// workstreams as a master view, and drilling into one navigates the sidebar
/// to show ONLY that workstream's workspaces (master-detail), instead of the
/// single-level expand/collapse a `WorkspaceGroup` provides.
///
/// Membership is stored on the workspace itself (`Workspace.workstreamId`),
/// exactly mirroring how `WorkspaceGroup` membership lives on
/// `Workspace.groupId`. The two relations are orthogonal: a workspace can be
/// in a workstream AND in a group, so a drilled-in workstream still renders
/// its inline group headers. This struct stores only the workstream's identity,
/// display name, and optional appearance overrides — the order of workstreams
/// is defined by their position in `WorkspacesModel.workstreams`.
///
/// Unlike `WorkspaceGroup`, a workstream has no "anchor" workspace: it is a
/// pure container whose lifecycle is independent of any single workspace, so
/// closing the last workspace in a workstream leaves the (now empty)
/// workstream in place for the user to keep populating.
public struct Workstream: Identifiable, Equatable, Sendable {
    /// The workstream's stable identity. Unlike workspace ids, this survives
    /// app restart unchanged, so membership (`Workspace.workstreamId`) and the
    /// drill-in pointer (`WorkspacesModel.drilledInWorkstreamId`) reconnect
    /// directly on restore.
    public let id: UUID
    /// The workstream's display name (shown in the master list and breadcrumb).
    public var name: String
    /// Optional color override (hex string) for the workstream row. When nil,
    /// the row falls back to the app's default tint.
    public var customColor: String?
    /// Optional SF Symbol name for the workstream row icon. When nil, the row
    /// uses a default symbol (`rectangle.stack`).
    public var iconSymbol: String?

    /// Creates a workstream.
    public init(
        id: UUID,
        name: String,
        customColor: String? = nil,
        iconSymbol: String? = nil
    ) {
        self.id = id
        self.name = name
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}
