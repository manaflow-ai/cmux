import Bonsplit
import CmuxPanes
import Foundation

/// `Workspace` is the live host for its ``SplitCloseCoordinator``. Every member
/// either passes through to the authoritative `BonsplitController` split tree or
/// reads/writes the workspace's own close bookkeeping (the `forceCloseTabIds`
/// bypass set and the close-history eligibility marks), reproducing the calls
/// the legacy `requestCloseTab` / `requestCloseTabRecordingHistory` bodies made
/// inline. The coordinator is held by `Workspace` and references this host
/// weakly, so there is no retain cycle.
///
/// Every witness this seam requires is already a `Workspace` member declared
/// elsewhere and shared with the sibling hosting conformances: `workspaceId`
/// and `panelId(forSurfaceId:)` are declared in the
/// ``SplitMoveReorderHosting`` conformance; `closeTab`,
/// `insertForceCloseTabId`, and `removeForceCloseTabId` are declared for the
/// ``SplitDetachHosting`` conformance (the force-close witnesses forward to the
/// `forceCloseTabIds` set on `splitLifecycle` / ``SplitLifecycleCoordinator``);
/// and
/// `markCloseHistoryEligible(panelId:)` is the identically named `Workspace`
/// close-history helper. So this conformance adds no new witnesses — it only
/// declares that `Workspace` satisfies ``SplitCloseHosting`` from those single
/// implementations.
extension Workspace: SplitCloseHosting {}
