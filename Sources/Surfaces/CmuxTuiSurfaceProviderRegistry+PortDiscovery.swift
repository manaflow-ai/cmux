import Foundation

extension CmuxTuiSurfaceProviderRegistry {
    /// Refreshes fleet metadata without starting every machine's transport.
    /// A port retry uses this to pick up a newly assigned private address.
    func refreshMachineMetadata(machineID: String) async -> Bool {
        guard let provider = providers[machineID], let client = VMClient.shared else { return false }
        do {
            let summary = try await client.status(id: machineID)
            await links.setPrivateAddresses([summary.addressIPv4, summary.addressIPv6].compactMap { $0 }, for: machineID)
            provider.update(summary: summary)
            return true
        } catch {
            return false
        }
    }
}
