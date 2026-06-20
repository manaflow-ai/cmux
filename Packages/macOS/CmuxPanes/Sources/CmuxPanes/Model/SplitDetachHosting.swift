public import Foundation
public import Bonsplit

/// The workspace-side seam ``SplitDetachCoordinator`` drives the live split tree
/// and the workspace's surface bookkeeping through while detaching a surface for
/// transfer to another workspace.
///
/// **Why a synchronous read/write protocol and not value snapshots.**
/// ``SplitDetachCoordinator/detachSurface(panelId:)`` runs as one `@MainActor`
/// turn that marks the surface mid-detach, force-closes its `BonsplitController`
/// tab (which routes the close into a transfer capture rather than a destructive
/// teardown), augments the captured transfer with the workspace's remote-cleanup
/// configuration when the workspace is losing its last remote terminal, and
/// publishes the surface-closed lifecycle event, exactly as the legacy
/// `Workspace.detachSurface` body did. The split tree and per-pane tab order are
/// owned by `BonsplitController`; the surface-id-to-panel-id mapping, the panel
/// registry, the force-close set, the active-remote-terminal accounting, the
/// remote-cleanup configuration, and the lifecycle publish are owned by the
/// workspace. The coordinator reaches all of it through this seam so it never
/// holds the app-target `Workspace`, while every value it sees and every side
/// effect it triggers stay on the live state. The detach-choreography state
/// (mid-detach marks, the transfer capture, the detach-close transaction count)
/// lives in the ``SplitLayoutModel`` the coordinator holds directly, so it is not
/// part of this seam.
///
/// `Transfer` is the window's detached-surface transfer payload type (the app
/// target's `Workspace.DetachedSurfaceTransfer`, which carries `any Panel`
/// references and app-domain snapshots, so it stays app-side). The two
/// transfer-shaped decisions — whether a captured transfer is a remote terminal
/// and applying the workspace's remote-cleanup configuration to it — are reached
/// through this seam rather than reimplemented in the package, because they read
/// app-domain fields on the app-side `Transfer`. The bonsplit pass-throughs
/// mirror the legacy `bonsplitController.*` calls one-for-one; the workspace
/// pass-throughs mirror the legacy `Workspace` helper calls
/// (`surfaceIdFromPanelId`, `paneId(forPanelId:)`, the `forceCloseTabIds`
/// mutations, `activeRemoteTerminalSurfaceIds` read,
/// `skipControlMasterCleanupAfterDetachedRemoteTransfer` write,
/// `publishCmuxSurfaceClosed`) with their default arguments preserved at the
/// conformance.
@MainActor
public protocol SplitDetachHosting<Transfer>: AnyObject {
    /// The window's detached-surface transfer payload type (the app target's
    /// `Workspace.DetachedSurfaceTransfer`).
    associatedtype Transfer

    /// The owning workspace's identity, for DEBUG logging (legacy `Workspace.id`).
    var workspaceId: UUID { get }

    // MARK: Surface / pane resolution (legacy `Workspace` helpers)

    /// Resolves the bonsplit surface id owning the given panel id, or `nil`
    /// (legacy `Workspace.surfaceIdFromPanelId`).
    func surfaceId(forPanelId panelId: UUID) -> TabID?

    // MARK: Source-panel capture + surface-closed publish
    //
    // The legacy `Workspace.detachSurface` captured the source panel
    // (`panels[panelId]`) and its pane id BEFORE closing the bonsplit tab, then
    // passed that captured panel to `publishCmuxSurfaceClosed` AFTER the close —
    // by which time the close pipeline has already removed the entry from
    // `panels`. The `any Panel` the publish needs is an app type that cannot
    // cross the seam, so the capture and the publish both live host-side: the
    // coordinator orchestrates the ordering by calling these two methods, and the
    // host holds the captured panel for the single synchronous detach turn (no
    // awaits, no nested detach, so one stash slot is safe).

    /// Captures the source panel for the panel id (its pre-close `panels[panelId]`
    /// and its `paneId(forPanelId:)`) so the surface-closed publish can use them
    /// after the close removes the registry entry. Returns `false` when the
    /// workspace owns no panel for the id, matching the legacy
    /// `guard let sourcePanel = panels[panelId]` bail (the coordinator returns
    /// `nil` without touching the split tree). Must be paired with exactly one
    /// ``publishCapturedDetachSource(transferCaptured:)``.
    func captureDetachSource(panelId: UUID) -> Bool

    /// Publishes the surface-closed lifecycle event for the captured source panel
    /// (legacy `Workspace.publishCmuxSurfaceClosed(_:paneId:panel:origin:)` with
    /// the captured panel and pane id), then clears the capture. `origin` is
    /// `"detach"` when a transfer was captured and `"detach_lost"` otherwise,
    /// matching the legacy body.
    func publishCapturedDetachSource(transferCaptured: Bool)

    /// Clears the captured source panel without publishing, used on the
    /// close-rejected failure path where the legacy body discarded its captured
    /// `sourcePanel`/`sourcePaneId` locals and returned `nil` without publishing.
    func discardCapturedDetachSource()

    // MARK: Bonsplit pass-through

    /// Closes a surface tab, returning whether the close took (legacy
    /// `bonsplitController.closeTab(_:)`).
    @discardableResult
    func closeTab(_ tabId: TabID) -> Bool

    // MARK: Force-close + remote accounting (legacy `Workspace` state)

    /// Inserts a surface id into the force-close set so the close pipeline skips
    /// confirmation (legacy `Workspace.forceCloseTabIds.insert`).
    func insertForceCloseTabId(_ tabId: TabID)

    /// Removes a surface id from the force-close set (legacy
    /// `Workspace.forceCloseTabIds.remove`).
    func removeForceCloseTabId(_ tabId: TabID)

    /// Whether the given panel id is one of the workspace's active remote
    /// terminal surfaces (legacy `Workspace.activeRemoteTerminalSurfaceIds.contains`).
    func isActiveRemoteTerminalSurface(_ panelId: UUID) -> Bool

    /// The number of active remote terminal surfaces in the workspace (legacy
    /// `Workspace.activeRemoteTerminalSurfaceIds.count`).
    var activeRemoteTerminalSurfaceCount: Int { get }

    /// Records that control-master cleanup must be skipped after the workspace's
    /// last remote terminal is detached for transfer (legacy
    /// `Workspace.skipControlMasterCleanupAfterDetachedRemoteTransfer = true`).
    func markSkipControlMasterCleanupAfterDetachedRemoteTransfer()

    // MARK: Transfer-shaped decisions (read app-domain fields on `Transfer`)

    /// Whether the captured transfer is a remote terminal (legacy
    /// `detachedTransfer.isRemoteTerminal`).
    func isRemoteTerminal(_ transfer: Transfer) -> Bool

    /// Returns a copy of the transfer carrying the workspace's current
    /// remote-cleanup configuration when the transfer does not already have one,
    /// otherwise the transfer unchanged (legacy
    /// `detachedTransfer.withRemoteCleanupConfiguration(remoteConfiguration)`
    /// guarded by `detachedTransfer.remoteCleanupConfiguration == nil`).
    func transferAdoptingRemoteCleanupConfigurationIfNeeded(_ transfer: Transfer) -> Transfer
}
