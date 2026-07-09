public import Foundation

/// The window-side seam ``SessionSnapshotRestoreCoordinator`` drives for the
/// irreducibly-app steps of a whole-window session-snapshot restore: the steps
/// that touch the `TabManager`/`Workspace` god types, app-static port-ordinal
/// state, the closed-item history singleton, and the `@Published` stored
/// properties (`tabs`/`selectedTabId`/`workspaceGroups`) that cannot cross the
/// module boundary.
///
/// **Why a synchronous two-way protocol.** The entire restore runs inside one
/// MainActor turn. Its ordering is load-bearing: the new workspace list is built
/// off-publish, then every `@Published` property is committed in a single atomic
/// assignment so SwiftUI observers never see an intermediate empty-`tabs` /
/// `nil`-selection state (the #399 frozen-blank-launch race). Pushing any leg
/// through a stream would open a suspension window in which pane/tab mutations
/// could interleave, observably changing the restored state. The coordinator
/// stays `@MainActor` and calls the host synchronously; the per-window
/// `TabManager` is the single conformer. This mirrors
/// ``WorkspaceSessionRestoreHosting``.
///
/// The conformer owns the god-coupled work; the coordinator owns the *sequence*
/// (reset → build off-publish → resolve selection/groups → atomic commit →
/// prune/release/schedule/remap/post) and the pure decisions inside it
/// (selection index, group member maps, stale-group filtering). The package
/// never imports the `TabManager`/`Workspace` god types.
@MainActor
public protocol SessionSnapshotRestoreHosting<Tab>: AnyObject {
    /// The per-window workspace ("tab") type the host constructs and commits.
    /// The app target's `Workspace` is the single conformer.
    associatedtype Tab: WorkspaceTabRepresenting

    /// Marks the start of a restore so the host can suppress selection
    /// side-effects for its duration (legacy `isRestoringSessionSnapshot = true`
    /// guarding the `selectedTabId` didSet). Paired with
    /// ``endSessionSnapshotRestore()`` which the coordinator calls from a
    /// `defer` so it runs even if a step throws.
    func beginSessionSnapshotRestore()

    /// Marks the end of a restore (legacy `isRestoringSessionSnapshot = false`).
    func endSessionSnapshotRestore()

    /// The window's current workspaces, captured before any mutation (legacy
    /// `let previousTabs = tabs`). The coordinator passes these back to
    /// ``resetSubModels(previousTabs:)`` and ``releaseAwayWorkspaces(_:)`` so the
    /// host reads its `tabs` exactly once.
    func currentWorkspaces() -> [Tab]

    /// Resets the per-window sub-model and history state that a restore clears
    /// before rebuilding, reproducing the legacy reset block in order: unwiring
    /// each previous workspace's closed-browser tracking, removing that
    /// workspace's closed-panel records, resetting the git-probe tracking,
    /// the focused-surface and pending-title and focus-history state (plus the
    /// focus-history revision and selection-side-effects generation bumps), the
    /// workspace-cycle hot window, and the recently-closed browser panels.
    ///
    /// These touch a mix of package sub-models and app-stored generation
    /// counters; the host owns the whole block so the coordinator does not need a
    /// reference to every sub-model just to call its reset.
    func resetSubModels(previousTabs: [Tab])

    /// Builds the new workspace list off-publish and returns it for the
    /// coordinator to finish sequencing (legacy lines that mint each `Workspace`,
    /// run its per-workspace `restoreSessionSnapshot`, wire its closed-browser
    /// tracking, allocate its port ordinal, and inject the fallback workspace
    /// when the snapshot restored none). No `@Published` property is mutated
    /// here; that is the point of the off-publish build.
    ///
    /// - Parameter excludingStableIdentities: stable workspace and surface
    ///   identities that must not be re-adopted while replaying the snapshot.
    func buildRestoredWorkspaces(excludingStableIdentities: Set<UUID>) -> SessionSnapshotRestoreBuild<Tab>

    /// Commits the fully resolved restore state in one atomic assignment of the
    /// `@Published` stored properties (legacy `tabs = newTabs`,
    /// `workspaceGroups = restoredGroups`, `selectedTabId = newSelectedId`, in
    /// that order), clearing any group reference on a restored workspace that no
    /// longer names a known group first (legacy stale-group cleanup loop, whose
    /// `knownGroupIds` set the coordinator computed). SwiftUI observers see the
    /// transition exactly once.
    func commitRestoredState(
        tabs: [Tab],
        groups: [WorkspaceGroup],
        knownGroupIds: Set<UUID>,
        selectedTabId: UUID?
    )

    /// Prunes background workspace loads and intersects the sidebar
    /// multi-selection down to the surviving ids (legacy
    /// `pruneBackgroundWorkspaceLoads(existingIds:)` +
    /// `sidebarMultiSelection.intersectSelection(with:)`), run after the atomic
    /// commit with the new id set.
    func pruneBackgroundLoadsAndSelection(existingIds: Set<UUID>)

    /// Tears down each pre-restore workspace after the atomic swap (legacy
    /// `releaseRestoredAwayWorkspace` over `previousTabs`), so late
    /// panel/socket callbacks cannot mutate hidden pre-restore state.
    func releaseAwayWorkspaces(_ previousTabs: [Tab])

    /// Schedules the initial git-metadata refresh for every terminal panel of
    /// every restored workspace (legacy nested loop calling
    /// `scheduleInitialWorkspaceGitMetadataRefreshIfPossible(workspaceId:panelId:)`).
    func scheduleInitialGitMetadata(for tabs: [Tab])

    /// Applies the planned closed-panel-history remaps to the closed-item history
    /// store (legacy `applyClosedPanelHistoryRemaps`). The store
    /// (`ClosedItemHistoryStore.shared`) stays app-side; its
    /// de-singletonization is deferred to a later slice.
    func applyClosedPanelHistoryRemaps(_ operations: [ClosedPanelHistoryRemapOperation])

    /// Posts the `ghosttyDidFocusTab` notification for the freshly selected
    /// workspace (legacy `NotificationCenter.default.post(name: .ghosttyDidFocusTab …)`),
    /// the final step of a restore. Called only when a selection resolved.
    func postDidFocusTab(selectedTabId: UUID)
}
