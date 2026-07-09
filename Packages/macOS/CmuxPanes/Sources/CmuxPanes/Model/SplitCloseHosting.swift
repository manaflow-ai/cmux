public import Foundation
public import Bonsplit

/// The workspace-side seam ``SplitCloseCoordinator`` drives the live split tree
/// and the workspace's close bookkeeping through.
///
/// **Why a synchronous read/write protocol and not value snapshots.** Each
/// close command lifted into the coordinator
/// (``SplitCloseCoordinator/requestCloseTab(_:force:)``,
/// ``SplitCloseCoordinator/requestCloseTabRecordingHistory(_:force:)``) runs as
/// one `@MainActor` turn that toggles the workspace's `forceCloseTabIds`
/// bypass set, asks the authoritative `BonsplitController` to close the tab
/// (which synchronously fires the workspace's `BonsplitDelegate` close
/// callbacks), and rolls the bypass mark back when the close is rejected,
/// exactly as the legacy `Workspace.requestCloseTab` / closing-history bodies
/// did. The force-close bypass set and the close-history eligibility marks are
/// owned by the workspace (the `BonsplitDelegate` callbacks read them mid-turn,
/// so they cannot move into a coordinator without widening that conformance);
/// the split tree and per-pane tab order are owned by `BonsplitController`. The
/// coordinator reaches all of it through this seam so it never holds the
/// app-target `Workspace`, while every value it sees and every side effect it
/// triggers stay on the live state.
///
/// The witnesses mirror the legacy inline calls one-for-one:
/// `insertForceCloseTabId` / `removeForceCloseTabId` are the
/// `forceCloseTabIds.insert` / `.remove` mutations, `closeTab` is
/// `bonsplitController.closeTab`, `panelId(forSurfaceId:)` is
/// `panelIdFromSurfaceId`, and `markCloseHistoryEligible(panelId:)` is the
/// identically named `Workspace` helper. `insertForceCloseTabId`,
/// `removeForceCloseTabId`, and `closeTab` are the same requirements
/// ``SplitDetachHosting`` already declares; `panelId(forSurfaceId:)` is shared
/// with ``SplitMoveReorderHosting``. A single `Workspace` implementation
/// satisfies all of them.
@MainActor
public protocol SplitCloseHosting: AnyObject {
    /// The owning workspace's identity, kept for parity with the sibling
    /// hosting seams (legacy `Workspace.id`).
    var workspaceId: UUID { get }

    /// Resolves the panel id owning the given bonsplit surface id, or `nil`
    /// (legacy `Workspace.panelIdFromSurfaceId`).
    func panelId(forSurfaceId surfaceId: TabID) -> UUID?

    /// Marks the panel (and its surface) close-history eligible so a subsequent
    /// close records a restorable entry (legacy
    /// `Workspace.markCloseHistoryEligible(panelId:)`).
    func markCloseHistoryEligible(panelId: UUID)

    /// Inserts a tab id into the force-close bypass set so the workspace's
    /// `BonsplitDelegate` `shouldCloseTab` callback allows the close (legacy
    /// `Workspace.forceCloseTabIds.insert`).
    func insertForceCloseTabId(_ tabId: TabID)

    /// Removes a tab id from the force-close bypass set, rolling back a forced
    /// close that bonsplit rejected (legacy `Workspace.forceCloseTabIds.remove`).
    func removeForceCloseTabId(_ tabId: TabID)

    /// Closes a surface tab in the authoritative split tree, returning whether
    /// it took. The call synchronously drives the workspace's `BonsplitDelegate`
    /// close callbacks (legacy `bonsplitController.closeTab(_:)`).
    @discardableResult
    func closeTab(_ tabId: TabID) -> Bool
}
