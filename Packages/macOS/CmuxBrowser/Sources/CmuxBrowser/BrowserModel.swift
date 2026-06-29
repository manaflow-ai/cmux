public import Foundation
import Observation

/// Per-window browser sub-model: owns the recently-closed browser panel
/// stack TabManager used to hold inline (`recentlyClosedBrowsers`).
///
/// `@MainActor` because every mutator and reader is a MainActor UI path
/// (the workspace close-panel callback, workspace teardown, the
/// Cmd+Shift+T reopen loop, the History menu) — state lives where its
/// callers live.
///
/// Generic over the window's restore-snapshot value: the full payload is
/// Workspace-owned (and migrates with the Workspace decomposition); this
/// model only needs ``BrowserPanelRestoreSnapshot`` identity. The
/// workspace/pane-coupled reopen walk stays app-side until the Wave-4
/// workspace/pane sub-models exist, popping entries through
/// ``BrowserManaging``.
@MainActor
@Observable
public final class BrowserModel<Snapshot: BrowserPanelRestoreSnapshot>: BrowserManaging {
    /// The legacy capacity of the reopen history (20 panels per window).
    public static var defaultRecentlyClosedCapacity: Int { 20 }

    private var recentlyClosedBrowsers: RecentlyClosedBrowserStack<Snapshot>

    /// Creates an empty model retaining at most `recentlyClosedCapacity`
    /// closed-panel snapshots.
    public init(recentlyClosedCapacity: Int = BrowserModel.defaultRecentlyClosedCapacity) {
        self.recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: recentlyClosedCapacity)
    }

    public var mostRecentClosedBrowserPanelClosedAt: Date? {
        recentlyClosedBrowsers.mostRecentClosedAt
    }

    public func recordClosedBrowserPanel(_ snapshot: Snapshot) {
        recentlyClosedBrowsers.push(snapshot)
    }

    public func popMostRecentlyClosedBrowserPanel() -> Snapshot? {
        recentlyClosedBrowsers.pop()
    }

    public func removeClosedBrowserPanels(forWorkspaceId workspaceId: UUID) {
        recentlyClosedBrowsers.removeSnapshots(forWorkspaceId: workspaceId)
    }

    public func clearRecentlyClosedBrowserPanels() {
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: recentlyClosedBrowsers.capacity)
    }
}
