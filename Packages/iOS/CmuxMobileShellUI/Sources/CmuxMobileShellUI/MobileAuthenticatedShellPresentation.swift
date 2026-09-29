import CmuxMobileShellModel

enum MobileAuthenticatedShellPresentation: Equatable {
    case disconnected
    case workspace

    static func resolve(
        connectionState: MobileConnectionState,
        hasKnownPairedMac: Bool,
        hasHiddenComputers: Bool,
        hasSSHComputers: Bool = false
    ) -> Self {
        // SSH computers are listed in the workspace shell, so a user with
        // only SSH computers never lands on the pair-a-Mac screen (PRD D5/D6).
        if connectionState != .connected,
           !hasKnownPairedMac,
           !hasHiddenComputers,
           !hasSSHComputers {
            return .disconnected
        }
        return .workspace
    }
}
