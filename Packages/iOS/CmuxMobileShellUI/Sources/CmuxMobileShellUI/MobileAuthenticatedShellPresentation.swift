import CmuxMobileShellModel

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
}
