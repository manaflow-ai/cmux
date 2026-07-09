public import Foundation

/// The app-coupled effects ``SurfaceMetadataCoordinator``'s panel-title
/// coalescing flow reaches back into.
///
/// The coordinator owns the coalescing bookkeeping (the pending per-surface
/// title batch, the flush loop, and the ``NotificationBurstCoalescer`` that
/// schedules the flush) — pure workspace-list state — but two pieces of the
/// legacy `TabManager` bodies are irreducibly app-target: the `NSWindow`-title
/// refresh for the *selected* workspace (`updateWindowTitle`, which reaches
/// `WindowTitleTemplate`, workspace groups, and the live `NSWindow`), and the
/// DEBUG `workspace.title.enqueue` log line (whose `cmuxDebugLog` sink and
/// id/title formatting stay app-side, exactly like
/// ``WorkspaceTitleHosting/workspaceTitleLogApplyProcess(from:to:)``).
///
/// The app target's `TabManager` conforms and is injected via
/// ``SurfaceMetadataCoordinator/attach(titleHost:)``. Every member mirrors a
/// call the legacy `enqueuePanelTitleUpdate` / `updatePanelTitle` /
/// `focusedSurfaceTitleDidChange` bodies made on `self`, so the move is
/// byte-faithful.
@MainActor
public protocol SurfaceMetadataTitleHosting: AnyObject {
    /// Refreshes the window title when `workspaceId` is the selected workspace
    /// (legacy `if selectedTabId == tabId { updateWindowTitle(for: tab) }`). The
    /// host owns `selectedTabId` and the `NSWindow`-title chrome, so the
    /// selected-workspace guard and the window-title write stay app-side.
    func surfaceMetadataUpdateWindowTitleIfSelected(workspaceId: UUID)

    /// Emits the DEBUG `workspace.title.enqueue` log line the legacy
    /// `enqueuePanelTitleUpdate` wrote for each accepted title. A no-op in
    /// release builds; kept on the host so the `cmuxDebugLog` sink and the
    /// workspace-id / title-preview formatting stay app-side.
    func surfaceMetadataLogPanelTitleEnqueue(
        workspaceId: UUID,
        panelId: UUID,
        title: String
    )
}
