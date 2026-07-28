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
        guard let workspace = eligible.first(where: {
            $0.macDeviceID.map(cmxCanonicalDeviceID) == canonicalForegroundID
        }), let terminalID = Self.releaseGateTerminal(in: workspace)?.id else {
            return nil
        }
        return (workspace, terminalID)
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
