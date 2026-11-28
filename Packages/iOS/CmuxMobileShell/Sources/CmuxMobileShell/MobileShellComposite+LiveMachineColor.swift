import Foundation

extension MobileShellComposite {
    /// Resolve an automatic avatar slot from the supplied pairing ids, but only
    /// when the pairing is currently represented in the live workspace state.
    ///
    /// ``machineColorIndex`` intentionally retains historical assignments so a
    /// transient Mac switch cannot recolor an existing workspace. Consumers that
    /// reconcile stored aliases, such as the Computers screen, must therefore
    /// filter that lifetime map through ``workspacesByMac`` before choosing a
    /// color for one logical Mac.
    public func liveMachineColorIndex(for pairingIDs: [String]) -> Int? {
        let livePairingIDs = Set(
            workspacesByMac.keys
                .filter { $0 != .anonymousForeground }
                .map(\.pairingID)
        )
        for pairingID in pairingIDs where livePairingIDs.contains(pairingID) {
            if let colorIndex = machineColorIndex[pairingID] {
                return colorIndex
            }
        }
        return nil
    }
}
