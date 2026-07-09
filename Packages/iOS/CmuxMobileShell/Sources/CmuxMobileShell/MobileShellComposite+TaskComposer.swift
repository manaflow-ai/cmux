public import CmuxMobilePairedMac
public import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Submit a task-composer workspace create request to the selected Mac.
    /// - Parameters:
    ///   - macDeviceID: Target Mac device id.
    ///   - spec: Workspace-create parameters derived from the selected template.
    /// - Returns: `success` when the workspace was created; otherwise the failure to display.
    @discardableResult
    public func submitTaskComposer(
        macDeviceID: String,
        spec: MobileWorkspaceCreateSpec
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        // A dropped connection can leave `foregroundMacDeviceID` pointing at the
        // selected Mac while `remoteClient` is already gone; a matching id alone
        // must not skip the switch, or the create fails as not-connected without
        // ever attempting a re-dial. `switchToMac` short-circuits when the
        // foreground connection to this Mac is genuinely live.
        if macDeviceID != foregroundMacDeviceID || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID) else {
                return .failure(.notConnected(hostDisplayName: taskComposerTargetName(macDeviceID: macDeviceID)))
            }
        }
        return await createWorkspaceRequest(spec: spec)
    }

    private func taskComposerTargetName(macDeviceID: String) -> String {
        displayPairedMacs.first { $0.macDeviceID == macDeviceID }?.resolvedName
            ?? pairedMacs.first { $0.macDeviceID == macDeviceID }?.resolvedName
            ?? macDeviceID
    }
}
