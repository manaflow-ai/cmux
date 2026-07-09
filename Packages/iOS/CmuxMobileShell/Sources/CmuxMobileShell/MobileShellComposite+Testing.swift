#if DEBUG
internal import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    /// Test seam: seed the full per-Mac workspace source of truth so aggregation
    /// edge cases can be tested without opening live secondary transports.
    func setWorkspaceStatesForTesting(
        _ states: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) {
        self.foregroundMacDeviceID = foregroundMacDeviceID
        workspacesByMac = states
    }

    func foregroundMacDeviceIDForTesting() -> String? { foregroundMacDeviceID }
    func storedMacReconnectGenerationForTesting() -> Int { storedMacReconnectGeneration }
}
#endif
