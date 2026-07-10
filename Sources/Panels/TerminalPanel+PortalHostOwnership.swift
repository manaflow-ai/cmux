extension TerminalPanel {
    /// Monotonic portal-host epoch across both container transfers and local
    /// representable reattachments. It supersedes host creation serial order.
    var portalHostOwnershipGeneration: UInt64 {
        surface.currentPortalHostOwnershipGeneration() &+ viewReattachToken
    }

    func recordPortalHostOwnershipChange() {
        requestViewReattach()
    }
}
