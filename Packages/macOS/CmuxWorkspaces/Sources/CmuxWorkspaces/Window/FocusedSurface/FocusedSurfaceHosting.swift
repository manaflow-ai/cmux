public import Foundation

/// The window-side seam the ``FocusedSurfaceModel`` drives: snapshot reads of
/// the window's selected workspace and panel existence/focus, plus the
/// synchronous focus/unfocus mutations the focus-restore and deferred-unfocus
/// state machine performs.
///
/// **Why a synchronous two-way protocol and not an AsyncStream.** Like the
/// focus-history seam, every focused-surface operation is one MainActor turn
/// that interleaves reads (does the workspace/panel still exist, what is the
/// workspace's focused panel) with writes (focus the restored panel, unfocus
/// the previous workspace's panel) and is itself re-entered synchronously from
/// the selection `didSet`. Pushing any leg through a stream would open a
/// suspension window in which user-driven mutations could interleave, an
/// observable change to focus handoff. The model stays `@MainActor` and calls
/// the host synchronously; the per-window `TabManager` is the single
/// implementer.
///
/// Reads return `false`/`nil` when the workspace or panel is gone, mirroring
/// the legacy optional-chained `tabs.first(where:)` lookups; mutations on a
/// gone workspace/panel are no-ops.
@MainActor
public protocol FocusedSurfaceHosting: AnyObject {
    /// The window's selected workspace id, if any (legacy `selectedTabId`).
    var selectedWorkspaceId: UUID? { get }
    /// Whether the panel still exists in the workspace (legacy
    /// `tab.panels[panelId] != nil`).
    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool
    /// The workspace's own focused panel id (legacy `tab.focusedPanelId`).
    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID?

    /// Focuses the panel in the workspace (legacy `tab.focusPanel(panelId)`).
    func focusPanel(workspaceId: UUID, panelId: UUID)
    /// Unfocuses the panel in the workspace (legacy `panel.unfocus()`), a
    /// no-op when the workspace or panel is gone.
    func unfocusPanel(workspaceId: UUID, panelId: UUID)

    /// Emits the legacy DEBUG trace for a deferred-unfocus decision. The host
    /// owns the `cmuxDebugLog` sink and the workspace-switch snapshot used to
    /// format the line; release builds make this a no-op.
    func logPendingWorkspaceUnfocusEvent(_ event: PendingWorkspaceUnfocusEvent)
}
