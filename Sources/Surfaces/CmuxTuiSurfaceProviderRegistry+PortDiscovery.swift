import Foundation

extension CmuxTuiSurfaceProviderRegistry {
    /// Refreshes fleet metadata without starting every machine's transport.
    /// A port retry uses this to pick up a newly assigned private address.
    func refreshMachineMetadata(machineID: String) async -> Bool {
        guard let providers = await discoverMachines(force: true, updateExisting: true) else { return false }
        return providers.contains { $0.machineID == machineID }
    }
}
