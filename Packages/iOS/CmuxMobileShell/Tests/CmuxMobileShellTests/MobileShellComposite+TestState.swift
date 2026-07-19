import CmuxMobileShellModel
@testable import CmuxMobileShell

@MainActor
extension MobileShellComposite {
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
