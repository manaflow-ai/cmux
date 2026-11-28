import CmuxMobileShellModel

enum MobileAuthenticatedShellPresentation: Equatable {
    case disconnected
    case workspace

    static func resolve(
        connectionState: MobileConnectionState,
        hasKnownPairedMac: Bool,
        hasHiddenComputers: Bool,
        hasSSHComputers: Bool = false,
        hasExternalHosts: Bool = false
    ) -> Self {
        // SSH computers and external hosts are listed in the workspace shell,
        // so they keep the user out of the pair-a-Mac-only screen.
        if connectionState != .connected,
           !hasKnownPairedMac,
           !hasHiddenComputers,
           !hasSSHComputers,
           !hasExternalHosts {
            return .disconnected
        }
        return .workspace
    }
}
