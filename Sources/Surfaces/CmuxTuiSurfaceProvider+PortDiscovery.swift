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

    /// Refreshes once a cached port scan expires. Later cache hits join the
    /// pending rescan, and the rescan itself scans, so this never repeats alone.
    func scheduleTrailingPortRescan(after delay: TimeInterval, lifecycle: UInt64) {
        guard trailingPortRescan == nil else { return }
        trailingPortRescan = Task { [weak self, attachmentClock] in
            do { try await attachmentClock.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.trailingPortRescan = nil
            guard self.isCurrentLifecycleGeneration(lifecycle), self.isRegisteredInCatalog() else { return }
            self.scheduleRefresh()
        }
    }
}
