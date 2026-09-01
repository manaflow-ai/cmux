import CmuxCore
import CmuxWorkspaces
import CmuxRemoteWorkspace
import Foundation

/// A cloud machine bound to a workspace through the cmux-tui remote daemon, persisted so a
/// restored `vm:<id>` workspace stays that machine's workspace (`workspace(forCloudVMID:)`,
/// the sidebar cloud button's Base reuse, `vm.terminal_open` targeting). Only the binding is
/// persisted: the pane's link is a process and is not replayed on restore.
struct SessionCloudVMBindingSnapshot: Codable, Sendable, Equatable {
    var vmID: String
    var isBase: Bool
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    /// Original workspace ID captured when the snapshot comes from a live workspace.
    /// Restore reuses this identity when it is present and non-colliding; legacy,
    /// externally-created, or duplicate snapshots can leave it nil or force a fresh ID.
    var workspaceId: UUID? = nil
    var stableId: UUID? = nil
    var taskCreateOperationID: UUID? = nil
    var processTitle: String
    var customTitle: String?
    /// Provenance of `customTitle`; absent provenance restores as user-set for compatibility.
    var customTitleSource: Workspace.CustomTitleSource? = nil
    var customDescription: String?
    var customColor: String?
    var customizationDirectory: String? = nil
    var usesWorkspaceDirectoryCustomization: Bool? = nil // `nil` infers a legacy local root.
    var isPinned: Bool
    var groupId: UUID? = nil
    var isManuallyUnread: Bool? = nil
    var hasUnreadIndicator: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var terminalScrollBarHidden: Bool?
    var currentDirectory: String
    /// Directory captured when the workspace was created. Optional for
    /// backwards compatibility with manifests written before declarative cwd
    /// policies existed.
    var workspaceRootDirectory: String? = nil
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    /// `WorkspaceLayoutMode` raw value; absent in pre-canvas snapshots (treated as splits).
    var layoutMode: String? = nil
    /// Canvas pane frames in z-order; persisted whenever any exist so
    /// positions survive toggling back to splits across restarts.
    var canvasPanes: [SessionCanvasPaneSnapshot]? = nil
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
    var remote: SessionRemoteWorkspaceSnapshot?
    /// cmux-tui cloud machine binding; absent in manifests written before the Cloud tree and for
    /// workspaces that are not cloud machines.
    var cloudVM: SessionCloudVMBindingSnapshot? = nil
    /// Remote surfaces this workspace's panes projected (`SurfaceCatalog`); absent for
    /// workspaces that only ever showed local panes, so older manifests decode unchanged.
    var surfaceProjections: [SurfaceProjectionRecord]? = nil
    /// Optional so manifests written before this field decode cleanly.
    var environment: [String: String]? = nil
    /// Manual task-status override raw values and the persisted checklist. Optional-with-nil-default
    /// (the `groupId` back-compat pattern); bridging to/from live `WorkspaceTodoState` lives in `SessionPersistence+Todos.swift`.
    var taskStatusOverride: String? = nil
    var taskStatusInferredAtOverride: String? = nil
    /// `true` when the workspace opted out of the status feature (None); absent for the default (feature engaged), so old manifests decode unchanged.
    var taskStatusHidden: Bool? = nil
    var checklist: [SessionChecklistItemSnapshot]? = nil
    var dock: SessionSplitContainerSnapshot? = nil // Missing legacy fields continue to seed from dock.json.
}

extension SessionWorkspaceSnapshot: WorkspaceSessionRemoteRestoreSnapshot {}
