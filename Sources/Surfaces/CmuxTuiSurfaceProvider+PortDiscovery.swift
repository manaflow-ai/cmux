import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Re-read only this machine's metadata, fencing deletion, replacement, account changes, and newer summaries.
    func refreshPortMetadata() async throws {
        guard isRegisteredInCatalog() else { throw CancellationError() }
        // Only Cloud machines have control-plane metadata. An SSH machine's loopback route needs none,
        // and its id must not reach the Cloud API.
        guard summary.cloudSummary != nil else { return }
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

    /// Runs one port-only rescan once the scan cache expires. A request made
    /// while one is pending or running runs once more after it, so a burst
    /// costs at most one scan per cache lifetime and stops when requests do.
    /// `followUp` also owes that one more scan, for a change that can come
    /// before the server it started is listening.
    func schedulePortRescan(followUp: Bool = false) {
        guard portDiscovery.mayScan else { return }
        guard portRescan == nil else {
            portRescanOwed = true
            return
        }
        portRescanOwed = followUp
        let lifecycle = currentLifecycleGeneration
        let delay = portDiscovery.rescanDelay(at: Date.now) ?? 0
        portRescan = Task { [weak self, attachmentClock] in
            if delay > 0 {
                do { try await attachmentClock.sleep(for: .seconds(delay)) } catch { return }
            }
            guard let self, self.isCurrentLifecycleGeneration(lifecycle) else { return }
            await self.rescanPorts()
            guard self.isCurrentLifecycleGeneration(lifecycle) else { return }
            self.portRescan = nil
            if self.portRescanOwed {
                self.portRescanOwed = false
                self.schedulePortRescan()
            }
        }
    }
}
