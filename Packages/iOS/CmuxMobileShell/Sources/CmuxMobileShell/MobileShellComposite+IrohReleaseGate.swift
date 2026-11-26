#if DEBUG
import CMUXMobileCore
public import CmuxMobileShellModel

extension MobileShellComposite {
    /// Returns a mutable workspace and terminal owned by the authenticated
    /// foreground Mac, excluding account-aggregated secondary Mac rows.
    public func irohReleaseGateForegroundTarget() -> (
        workspace: MobileWorkspacePreview,
        terminalID: MobileTerminalPreview.ID
    )? {
        let eligible = workspaces.filter {
            $0.actionCapabilities.supportsWorkspaceActions
                && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Self.releaseGateTerminal(in: $0) != nil
        }
        guard let foregroundMacDeviceID else {
            guard let workspace = eligible.first(where: { $0.macDeviceID == nil }),
                  let terminalID = Self.releaseGateTerminal(in: workspace)?.id else {
                return nil
            }
            return (workspace, terminalID)
        }
        let canonicalForegroundID = cmxCanonicalDeviceID(foregroundMacDeviceID)
        let foregroundTag = activeMacInstanceTag
        guard let workspace = eligible.first(where: {
            $0.macDeviceID.map(cmxCanonicalDeviceID) == canonicalForegroundID
                && macInstanceTagAuthority.sameStoredAuthority(
                    $0.macInstanceTag,
                    foregroundTag
                )
        }), let terminalID = Self.releaseGateTerminal(in: workspace)?.id else {
            return nil
        }
        return (workspace, terminalID)
    }

    /// Reacquires the current aggregate row for a workspace captured earlier in
    /// a long-running release gate. Account/device reconciliation may replace a
    /// SwiftUI row id while the Mac-local RPC workspace id remains stable.
    public func irohReleaseGateCurrentWorkspace(
        matching captured: MobileWorkspacePreview
    ) -> MobileWorkspacePreview? {
        let remoteWorkspaceID = captured.rpcWorkspaceID
        let expectedMacDeviceID = captured.macDeviceID ?? foregroundMacDeviceID
        let expectedInstanceTag = captured.macInstanceTag ?? activeMacInstanceTag
        let candidates = workspaces.filter {
            $0.rpcWorkspaceID == remoteWorkspaceID
                && $0.actionCapabilities.supportsWorkspaceActions
        }
        guard let expectedMacDeviceID else {
            return candidates.count == 1 ? candidates[0] : nil
        }
        let canonicalExpectedMacDeviceID = cmxCanonicalDeviceID(expectedMacDeviceID)
        return candidates.first {
            $0.macDeviceID.map(cmxCanonicalDeviceID) == canonicalExpectedMacDeviceID
                && macInstanceTagAuthority.sameStoredAuthority(
                    $0.macInstanceTag,
                    expectedInstanceTag
                )
        }
    }

    private static func releaseGateTerminal(
        in workspace: MobileWorkspacePreview
    ) -> MobileTerminalPreview? {
        workspace.terminals.first { $0.isReady && $0.isFocused }
            ?? workspace.terminals.first { $0.isReady }
            ?? workspace.terminals.first { $0.isFocused }
            ?? workspace.terminals.first
    }
}
#endif
