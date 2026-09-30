import CmuxMobileShellModel

enum MobileAuthenticatedShellPresentation: Equatable {
    case disconnected
    case workspace

    static func resolve(
        connectionState: MobileConnectionState,
        hasKnownPairedMac: Bool,
        hasHiddenComputers: Bool,
        hasExternalHosts: Bool = false
    ) -> Self {
        // An external host (a Cloud machine) is a computer: its workspaces
        // render in the shell, so the add-device screen would hide real,
        // reachable work — and the tab scaffold with it, making the Cloud tab
        // unreachable for exactly the no-Mac account it exists for.
        if hasExternalHosts { return .workspace }
        if connectionState != .connected,
           !hasKnownPairedMac,
           !hasHiddenComputers {
            return .disconnected
        }
        return .workspace
    }
}
