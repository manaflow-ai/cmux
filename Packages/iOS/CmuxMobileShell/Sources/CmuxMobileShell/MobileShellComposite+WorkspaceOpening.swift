public import CmuxMobileShellModel
import Foundation
internal import OSLog

private let mobileShellWorkspaceOpeningLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    /// Opens a workspace preview, switching the foreground Mac first when needed.
    /// - Parameter id: The aggregated workspace-row identifier to open.
    public func openWorkspace(_ id: MobileWorkspacePreview.ID) async {
        let workspace = workspaces.first { $0.id == id }
        let remoteWorkspaceID = workspace?.rpcWorkspaceID ?? id
        let ownerMacDeviceID = workspace?.macDeviceID
        let workspaceHadUnread = workspace?.hasUnread == true
        if multiMacAggregationEnabled,
           let macDeviceID = ownerMacDeviceID,
           !macDeviceID.isEmpty,
           macDeviceID != foregroundMacDeviceID {
            guard await switchToMac(macDeviceID: macDeviceID) else {
                // Approval is a suspended switch, not a failed switch. Keep the
                // selected row and bind its navigation intent to that exact attempt.
                if let pending = pendingManualHostTrust,
                   pending.pairedMacDeviceID == macDeviceID,
                   let macSwitchAttemptID = pending.macSwitchAttemptID {
                    pendingWorkspaceOpenIntent = PendingWorkspaceOpenIntent(
                        rowWorkspaceID: id,
                        remoteWorkspaceID: remoteWorkspaceID,
                        ownerMacDeviceID: ownerMacDeviceID,
                        workspaceHadUnread: workspaceHadUnread,
                        terminalCount: workspace?.terminals.count ?? 0,
                        isPinned: workspace?.isPinned ?? false,
                        macSwitchAttemptID: macSwitchAttemptID
                    )
                    return
                }
                mobileShellWorkspaceOpeningLog.error("openWorkspace: switch to mac failed, popping mac=\(macDeviceID, privacy: .public)")
                rollbackPendingWorkspaceOpen(rowWorkspaceID: id)
                return
            }
        }
        await finishWorkspaceOpen(
            requestedRowID: id,
            remoteWorkspaceID: remoteWorkspaceID,
            ownerMacDeviceID: ownerMacDeviceID,
            workspaceHadUnread: workspaceHadUnread,
            terminalCount: workspace?.terminals.count ?? 0,
            isPinned: workspace?.isPinned ?? false
        )
    }

    func takePendingWorkspaceOpenIntent(
        for pending: PendingManualHostTrust
    ) -> PendingWorkspaceOpenIntent? {
        guard let intent = pendingWorkspaceOpenIntent,
              pending.macSwitchAttemptID == intent.macSwitchAttemptID else {
            return nil
        }
        pendingWorkspaceOpenIntent = nil
        return intent
    }

    func cancelPendingWorkspaceOpenIntent() {
        guard let intent = pendingWorkspaceOpenIntent else { return }
        cancelWorkspaceOpen(intent)
    }

    func cancelWorkspaceOpen(_ intent: PendingWorkspaceOpenIntent) {
        pendingWorkspaceOpenIntent = nil
        rollbackPendingWorkspaceOpen(rowWorkspaceID: intent.rowWorkspaceID)
    }

    func resumePendingWorkspaceOpen(_ intent: PendingWorkspaceOpenIntent) async {
        await finishWorkspaceOpen(
            requestedRowID: intent.rowWorkspaceID,
            remoteWorkspaceID: intent.remoteWorkspaceID,
            ownerMacDeviceID: intent.ownerMacDeviceID,
            workspaceHadUnread: intent.workspaceHadUnread,
            terminalCount: intent.terminalCount,
            isPinned: intent.isPinned
        )
    }

    private func finishWorkspaceOpen(
        requestedRowID: MobileWorkspacePreview.ID,
        remoteWorkspaceID: MobileWorkspacePreview.ID,
        ownerMacDeviceID: String?,
        workspaceHadUnread: Bool,
        terminalCount: Int,
        isPinned: Bool
    ) async {
        let resolvedRowID = rowWorkspaceID(
            forRemoteWorkspaceID: remoteWorkspaceID,
            macDeviceID: ownerMacDeviceID
        ) ?? (workspaces.contains(where: { $0.id == requestedRowID }) ? requestedRowID : nil)
        guard let resolvedRowID else {
            mobileShellWorkspaceOpeningLog.error("openWorkspace: workspace disappeared after switch id=\(remoteWorkspaceID.rawValue, privacy: .private) mac=\(ownerMacDeviceID ?? "", privacy: .public)")
            rollbackPendingWorkspaceOpen(rowWorkspaceID: requestedRowID)
            return
        }
        analytics.capture("ios_workspace_opened", [
            "terminal_count": .int(terminalCount),
            "is_pinned": .bool(isPinned),
            "source": .string("list_tap"),
        ])
        setSelectedWorkspaceID(resolvedRowID)
        if supportsWorkspaceReadStateActions, workspaceHadUnread {
            await setWorkspaceUnread(id: resolvedRowID, false)
        }
    }

    private func rollbackPendingWorkspaceOpen(rowWorkspaceID: MobileWorkspacePreview.ID) {
        if selectedWorkspaceID == rowWorkspaceID {
            setSelectedWorkspaceID(nil)
        }
    }
}
