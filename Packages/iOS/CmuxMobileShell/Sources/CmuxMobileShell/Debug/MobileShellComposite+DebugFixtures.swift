#if DEBUG
import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Replaces foreground workspaces for DEBUG-only preview harnesses.
    public func replaceForegroundWorkspaceState(
        _ workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview] = []
    ) {
        setForegroundWorkspaceState(workspaces: workspaces, groups: groups, merge: false)
    }

    /// Seeds per-Mac workspace state for deterministic aggregation fixtures.
    func setWorkspaceStateSnapshot(
        _ states: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) {
        self.foregroundMacDeviceID = foregroundMacDeviceID
        workspacesByMac = Dictionary(
            uniqueKeysWithValues: states.map { (MacPairingKey(pairingID: $0.key), $0.value) }
        )
    }

    /// Marks a secondary Mac unavailable for a DEBUG refresh fixture.
    func markSecondaryMacUnavailableSnapshot(_ macID: String) {
        markSecondaryMacUnavailable(MacPairingKey(pairingID: macID))
    }

    /// Returns the current foreground Mac identifier for a fixture assertion.
    func foregroundMacDeviceIDSnapshot() -> String? { foregroundMacDeviceID }

    /// Returns the pooled route for a fixture assertion.
    func pooledRouteSnapshot(macDeviceID: String) -> CmxAttachRoute? {
        macConnectionRegistry.focusedConnection(onDevice: macDeviceID)?.route
            ?? macConnectionRegistry.controlSubscriptions.first {
                $0.key.isOnDevice(macDeviceID)
            }?.value.route
    }

    /// Recomputes registry routes for a deterministic fixture.
    func refreshRoutesFromRegistrySnapshot(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) {
        refreshRoutesFromRegistry(for: mac, scope: scope)
    }
}
#endif
