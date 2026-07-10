extension TerminalPanel {
    /// Monotonic portal-host epoch across container transfers and explicit
    /// representable reattachment requests.
    var portalHostOwnershipGeneration: UInt64 {
        surface.currentPortalHostOwnershipGeneration() &+ viewReattachToken
    }

    func recordPortalHostOwnershipChange() {
        requestViewReattach()
    }
}
