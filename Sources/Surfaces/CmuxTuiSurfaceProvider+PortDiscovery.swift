import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Re-read only this machine's metadata, fencing deletion, replacement, account changes, and newer summaries.
    func refreshPortMetadata() async throws {
        guard isRegisteredInCatalog() else { throw CancellationError() }
        let lifecycle = currentLifecycleGeneration
        let summaryVersion = summaryGeneration
        let next = try await loadPortSummary(machineID)
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog() else { throw CancellationError() }
        guard next.id == machineID else { throw ProviderError.invalidSnapshot(machineID) }
        guard summaryGeneration == summaryVersion else { return }
        await links.setPrivateAddresses([next.addressIPv4, next.addressIPv6].compactMap { $0 }, for: machineID)
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog(), summaryGeneration == summaryVersion else {
            throw CancellationError()
        }
        update(summary: next)
    }
}
