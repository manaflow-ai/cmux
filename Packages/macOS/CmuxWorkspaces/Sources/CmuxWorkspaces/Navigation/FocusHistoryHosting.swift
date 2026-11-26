public import Foundation

/// The window-side seam the focus-history model drives: snapshot reads of
/// workspace/panel existence, titles, and remembered focus, plus the
/// synchronous selection/focus mutations a history navigation performs.
///
/// **Why a synchronous two-way protocol and not an AsyncStream.** Every
/// legacy focus-history operation is one MainActor turn that interleaves
/// reads (does the workspace still exist, which panel resolves) with writes
/// (select the workspace, focus the panel, flash it) and with re-entrant
/// recording suppression (selecting a workspace synchronously re-enters the
/// model through the selection `didSet`). Pushing any leg through a stream
/// would open a suspension window in which user-driven mutations could
/// interleave — an observable change to navigation transitions. The model
/// therefore stays `@MainActor` and calls the host synchronously; the
/// per-window `TabManager` is the single implementer.
///
/// Reads return `false`/`nil` when the workspace or panel is gone,
/// mirroring the legacy optional-chained `tabs.first(where:)` lookups.
@MainActor
public protocol FocusHistoryHosting: AnyObject {
    // MARK: Selection / workspace reads

    /// The window's selected workspace id, if any.
    var selectedWorkspaceId: UUID? { get }
    /// Whether the workspace still exists in this window.
    func workspaceExists(_ workspaceId: UUID) -> Bool
    /// Whether the panel still exists in the workspace.
    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool
    /// The workspace's display title, or `nil` when the workspace is gone.
    func workspaceTitle(_ workspaceId: UUID) -> String?
    /// The panel's display title, when one exists.
    func panelTitle(workspaceId: UUID, panelId: UUID) -> String?
    /// The window-level remembered focused panel for the workspace (legacy
    /// `focusedPanelId(for:)`).
    func rememberedFocusedPanelId(_ workspaceId: UUID) -> UUID?
    /// The workspace's own focused panel id (legacy `workspace.focusedPanelId`).
    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID?
    /// The workspace's first panel id ordered by `uuidString` (the legacy
    /// deterministic fallback).
    func firstPanelIdSortedByUUIDString(_ workspaceId: UUID) -> UUID?

    // MARK: Navigation mutations

    /// Selects the workspace if it is not already selected (legacy
    /// `if selectedTabId != id { selectedTabId = id }`).
    func selectWorkspace(_ workspaceId: UUID)
    /// Remembers the focused surface for the workspace.
    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID)
    /// Focuses the panel in the workspace.
    func focusPanel(workspaceId: UUID, panelId: UUID)
    /// Triggers the focus flash on the panel.
    func triggerFocusFlash(workspaceId: UUID, panelId: UUID)
    /// Focuses the selected workspace's panel (legacy
    /// `focusSelectedTabPanel(previousTabId: nil)` fallback).
    func focusSelectedWorkspacePanel()

    // MARK: Change propagation

    /// Called after any observable history mutation; the host bumps its
    /// published revision counter (legacy `focusHistoryRevision &+= 1`).
    func focusHistoryRevisionDidChange()
}
