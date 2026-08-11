import CmuxMobileShellModel
import CmuxMobileWorkspace

enum MobileAuthenticatedShellPresentation: Equatable {
    case disconnected
    case workspace

    static func resolve(
        connectionState: MobileConnectionState,
        hasKnownPairedMac: Bool,
        hasHiddenComputers: Bool
    ) -> Self {
        if connectionState != .connected,
           !hasKnownPairedMac,
           !hasHiddenComputers {
            return .disconnected
        }
        return .workspace
    }

    /// Keeps a child sheet's owning shell mounted until that sheet's dismissal
    /// callback releases the root modal slot.
    static func retainingChildHost(
        _ requiredChildHost: MobileRootPresentationState.ChildHost?,
        over baseSurface: MobileRootAuthGate.MobileRootShellSurface
    ) -> MobileRootAuthGate.MobileRootShellSurface {
        switch requiredChildHost {
        case .disconnected:
            return .disconnectedNoKnownPairedMac
        case .workspace:
            if case .workspaceShell = baseSurface {
                return baseSurface
            }
            return .workspaceShell(isRestoringStoredMac: false)
        case nil:
            return baseSurface
        }
    }
}
