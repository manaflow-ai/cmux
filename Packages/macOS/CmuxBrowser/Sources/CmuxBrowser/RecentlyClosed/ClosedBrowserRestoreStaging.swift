public import Foundation
public import Bonsplit

/// Owns the per-tab staging of recently-closed browser restore snapshots that
/// the app-target `Workspace` used to inline as the
/// `pendingClosedBrowserRestoreSnapshots` dictionary plus its
/// `stageClosedBrowserRestoreSnapshotIfNeeded`/`clearStagedClosedBrowserRestoreSnapshot`
/// methods.
///
/// A browser tab close is a two-step flow: the Bonsplit close delegate stages a
/// snapshot for the closing tab (`stageSnapshotIfNeeded`), and once Bonsplit
/// confirms the close the workspace consumes it (`consumeSnapshot`) and hands it
/// to `TabManager` for the `Cmd+Shift+T` restore stack. The various close-gating
/// branches (pinned, confirmation-in-flight, close-workspace-on-last-surface,
/// already pushed to the panel-history stack) clear the staged entry instead.
///
/// The build decision is a byte-faithful lift of the legacy
/// `stageClosedBrowserRestoreSnapshotIfNeeded` body: the
/// `suppressClosedPanelHistory` gate drops any pending entry and returns; a
/// missing panel, non-browser panel, or missing tab index drops and returns; a
/// transient history/diff-viewer url drops and returns; otherwise the snapshot is
/// built from the resolved url, profile, origin pane/index, and fallback plan and
/// stored under the tab id. Every live read goes through
/// ``ClosedBrowserRestoreStagingHosting`` so this type never holds the
/// `Workspace` or any WebKit/AppKit type.
///
/// `@MainActor` because the whole close flow runs on the main actor (the Bonsplit
/// delegate and the workspace it drives both live there) — co-locating the
/// staging map with its callers removes any bridging, the same isolation ruling
/// as the sibling ``SurfaceLifecycleCoordinator``.
@MainActor
public final class ClosedBrowserRestoreStaging {
    private weak var host: (any ClosedBrowserRestoreStagingHosting)?
    private var pending: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]

    /// Creates the staging coordinator. Call ``attach(host:)`` before driving any
    /// staging operation.
    public init() {}

    /// Attaches the workspace-side host the staging decision reads through.
    public func attach(host: any ClosedBrowserRestoreStagingHosting) {
        self.host = host
    }

    /// Stages a restore snapshot for the closing `tab` in `pane` when it names a
    /// live browser panel showing a restorable page, dropping any prior pending
    /// entry for the tab otherwise. Byte-faithful lift of
    /// `Workspace.stageClosedBrowserRestoreSnapshotIfNeeded(for:inPane:)`.
    public func stageSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let host else {
            pending.removeValue(forKey: tab.id)
            return
        }
        guard !host.stagingSuppressClosedPanelHistory else {
            pending.removeValue(forKey: tab.id)
            return
        }
        guard let panelId = host.stagingPanelId(forSurfaceId: tab.id),
              host.stagingIsBrowserPanel(panelId: panelId),
              let tabIndex = host.stagingTabIndex(forSurfaceId: tab.id, inPane: pane) else {
            pending.removeValue(forKey: tab.id)
            return
        }

        let fallbackPlan = host.stagingFallbackPlan(forPane: pane)
        let resolvedURL = host.stagingResolvedURL(panelId: panelId)
        guard !host.stagingIsTemporaryHistoryURL(resolvedURL) else {
            pending.removeValue(forKey: tab.id)
            return
        }

        pending[tab.id] = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: host.stagingWorkspaceId,
            url: resolvedURL,
            profileID: host.stagingProfileID(panelId: panelId),
            originalPaneId: pane.id,
            originalTabIndex: tabIndex,
            fallbackSplitOrientation: fallbackPlan?.orientation,
            fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
            fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
        )
    }

    /// Drops any staged snapshot for `tabId`. Byte-faithful lift of
    /// `Workspace.clearStagedClosedBrowserRestoreSnapshot(for:)`.
    public func clearSnapshot(forTabId tabId: TabID) {
        pending.removeValue(forKey: tabId)
    }

    /// Removes and returns the staged snapshot for `tabId`, if any, mirroring the
    /// legacy `pendingClosedBrowserRestoreSnapshots.removeValue(forKey:)` the
    /// close delegate performed before firing the closed-browser callback.
    public func consumeSnapshot(forTabId tabId: TabID) -> ClosedBrowserPanelRestoreSnapshot? {
        pending.removeValue(forKey: tabId)
    }
}
