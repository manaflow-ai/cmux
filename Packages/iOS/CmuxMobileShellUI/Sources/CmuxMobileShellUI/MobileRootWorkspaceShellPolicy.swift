struct MobileRootWorkspaceShellPolicy {
    let isConnected: Bool
    let hasKnownPairedMac: Bool
    let isRestoringStoredMac: Bool

    var keepsWorkspaceShellMounted: Bool {
        isConnected || hasKnownPairedMac || isRestoringStoredMac
    }
}
