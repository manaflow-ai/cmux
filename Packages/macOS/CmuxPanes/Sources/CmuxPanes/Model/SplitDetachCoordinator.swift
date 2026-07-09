public import Foundation
internal import Bonsplit
#if DEBUG
import CMUXDebugLog
#endif

/// Drives a workspace's surface detach command against the live split tree:
/// detaching a surface from this workspace for transfer to another workspace,
/// capturing the transfer payload without destroying the surface.
///
/// This command is lifted one-for-one from the legacy `Workspace`
/// Panel-Operations body (`detachSurface(panelId:)`). The detach-choreography
/// state (mid-detach marks, the captured transfer payload, the detach-close
/// transaction count) lives in the ``SplitLayoutModel`` the coordinator holds
/// directly; every split-tree mutation and every workspace-side side effect
/// (force-close set, remote accounting, surface-closed publish) is reached
/// through ``SplitDetachHosting`` so this type never holds the app-target
/// `Workspace`, while the state it mutates and the events it publishes are always
/// the live ones. The transfer-shaped decisions (whether the captured transfer is
/// a remote terminal, and adopting the workspace's remote-cleanup configuration
/// into it) read app-domain fields on the app-side `Transfer`, so they too go
/// through the host.
///
/// `Transfer` is the window's detached-surface transfer payload type, the same
/// type the coordinator's ``SplitLayoutModel`` is parameterized over (the app
/// target's `Workspace.DetachedSurfaceTransfer`).
@MainActor
public final class SplitDetachCoordinator<Transfer> {
    private let splitLayout: SplitLayoutModel<Transfer>
    private weak var host: (any SplitDetachHosting<Transfer>)?

    /// Creates the coordinator over the workspace's split-layout sub-model (the
    /// owner of the detach-choreography state). Call ``attach(host:)`` before use.
    public init(splitLayout: SplitLayoutModel<Transfer>) {
        self.splitLayout = splitLayout
    }

    /// Attaches the workspace-side host the command drives through.
    public func attach(host: any SplitDetachHosting<Transfer>) {
        self.host = host
    }

    /// Detaches the surface owning `panelId` from this workspace, returning the
    /// captured transfer payload (or `nil` when the surface is unknown or the
    /// close is rejected). Lifted one-for-one from `Workspace.detachSurface`.
    public func detachSurface(panelId: UUID) -> Transfer? {
        guard let host else { return nil }
        guard let tabId = host.surfaceId(forPanelId: panelId) else { return nil }
        guard host.captureDetachSource(panelId: panelId) else { return nil }
        let shouldSkipControlMasterCleanupAfterDetach =
            host.isActiveRemoteTerminalSurface(panelId)
            && host.activeRemoteTerminalSurfaceCount == 1
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        CMUXDebugLog.logDebugEvent(
            "split.detach.begin ws=\(host.workspaceId.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(splitLayout.activeDetachCloseTransactions) " +
            "pendingDetached=\(splitLayout.pendingDetachedSurfaces.count)"
        )
#endif

        splitLayout.markDetaching(tabId)
        host.insertForceCloseTabId(tabId)
        splitLayout.openDetachCloseTransaction()
        defer { splitLayout.closeDetachCloseTransaction() }
        guard host.closeTab(tabId) else {
            splitLayout.cancelDetach(tabId)
            host.removeForceCloseTabId(tabId)
            host.discardCapturedDetachSource()
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "split.detach.fail ws=\(host.workspaceId.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(Self.debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        var detached = splitLayout.takeDetachedTransfer(tabId)
        if shouldSkipControlMasterCleanupAfterDetach, let detachedTransfer = detached, host.isRemoteTerminal(detachedTransfer) {
            host.markSkipControlMasterCleanupAfterDetachedRemoteTransfer()
            detached = host.transferAdoptingRemoteCleanupConfigurationIfNeeded(detachedTransfer)
        }
        host.publishCapturedDetachSource(transferCaptured: detached != nil)
#if DEBUG
        CMUXDebugLog.logDebugEvent(
            "split.detach.end ws=\(host.workspaceId.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(Self.debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
    }

#if DEBUG
    /// Formats milliseconds since a `systemUptime` mark for DEBUG detach logs
    /// (legacy `Workspace.debugElapsedMs(since:)`).
    private static func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif
}
