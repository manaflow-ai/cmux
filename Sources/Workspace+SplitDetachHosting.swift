import Bonsplit
import CmuxPanes
import Foundation

/// `Workspace` is the live host for its ``SplitDetachCoordinator``. Each member
/// either passes through to the authoritative `BonsplitController` split tree,
/// reads/writes the workspace's own detach bookkeeping, reads the app-domain
/// `DetachedSurfaceTransfer` value, or publishes the surface-closed lifecycle
/// event, reproducing the calls the legacy Panel-Operations `detachSurface`
/// body made inline. The coordinator is held by `Workspace` and references this
/// host weakly, so there is no retain cycle.
///
/// `workspaceId` and `surfaceId(forPanelId:)` are shared witnesses with the
/// ``SplitMoveReorderHosting`` / ``SurfaceLifecycleHosting`` conformances
/// (identical requirements); they are declared in those files and satisfy this
/// protocol from the single `Workspace` implementations. The witnesses that
/// touch `private` detach state (`insertForceCloseTabId`,
/// `removeForceCloseTabId`, `isActiveRemoteTerminalSurface`,
/// `activeRemoteTerminalSurfaceCount`,
/// `markSkipControlMasterCleanupAfterDetachedRemoteTransfer`) and the
/// source-panel capture/publish/discard witnesses (which read/write the
/// `private` capture stash) are declared in `Workspace.swift`, co-located with
/// that state so it stays `private`. The witnesses below are the ones that need
/// no private access: the bonsplit close pass-through and the two
/// transfer-shaped decisions reading the app-domain `DetachedSurfaceTransfer`.
extension Workspace: SplitDetachHosting {
    func closeTab(_ tabId: TabID) -> Bool {
        bonsplitController.closeTab(tabId)
    }

    func isRemoteTerminal(_ transfer: DetachedSurfaceTransfer) -> Bool {
        transfer.isRemoteTerminal
    }

    func transferAdoptingRemoteCleanupConfigurationIfNeeded(
        _ transfer: DetachedSurfaceTransfer
    ) -> DetachedSurfaceTransfer {
        guard transfer.remoteCleanupConfiguration == nil else { return transfer }
        return transfer.withRemoteCleanupConfiguration(remoteConnectionCoordinator.state.remoteConfiguration)
    }
}
