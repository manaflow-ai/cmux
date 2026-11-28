public import Foundation

/// The cross-cutting browser-state reads and mutations the app target
/// performs against the per-window browser sub-model: recording closed
/// browser panels, draining them for Cmd+Shift+T reopen, and the recency
/// read the History menu sorts windows by.
///
/// `@MainActor` because every caller is a MainActor UI path (panel close
/// callbacks, workspace teardown, the reopen shortcut) — state lives where
/// its callers live.
@MainActor
public protocol BrowserManaging<Snapshot>: AnyObject {
    /// The restore-snapshot value the window's workspaces produce.
    associatedtype Snapshot: BrowserPanelRestoreSnapshot

    /// When the most recently closed browser panel was closed, if any.
    var mostRecentClosedBrowserPanelClosedAt: Date? { get }

    /// Records a closed browser panel for later reopen.
    func recordClosedBrowserPanel(_ snapshot: Snapshot)

    /// Removes and returns the most recently closed panel snapshot.
    func popMostRecentlyClosedBrowserPanel() -> Snapshot?

    /// Drops every snapshot owned by the given workspace (workspace closed).
    func removeClosedBrowserPanels(forWorkspaceId workspaceId: UUID)

    /// Clears the entire reopen history.
    func clearRecentlyClosedBrowserPanels()
}
