import Foundation

extension MachinesPanelViewModel {
    /// Which machines the stats poll samples this round: none while a create is in
    /// flight (the control plane's attention belongs to that request), never a
    /// machine whose link is still connecting, and only machines advertising stats.
    /// Sleeping machines report `asleep` without being woken, so sampling is free.
    nonisolated static func statsPollTargets(
        machines: [MachineSnapshot],
        catalog: SurfaceCatalogSnapshot,
        hasRunningCreate: Bool
    ) -> [String] {
        guard !hasRunningCreate else { return [] }
        let connecting = Set(catalog.machines.filter { $0.linkState == .connecting }.compactMap { $0.id.cloudMachineID })
        return machines.filter { $0.capabilities.stats && !connecting.contains($0.id) }.map(\.id)
    }

    /// Spreads one round of stats reads across the poll interval instead of firing
    /// them all in the same instant as the fleet list.
    nonisolated static func statsPollSchedule(ids: [String], interval: Duration) -> [(id: String, delay: Duration)] {
        guard !ids.isEmpty else { return [] }
        return ids.enumerated().map { (id: $0.element, delay: interval * $0.offset / ids.count) }
    }

    /// Samples machines advertising stats support. Older servers omitting the flag
    /// retain the desktop-only polling policy through capability decoding; explicit
    /// support overrides that fallback.
    func refreshStats() {
        guard CloudMachinesFeature.isEnabled, let client = VMClient.shared else { return }
        statsTask?.cancel()
        let schedule = Self.statsPollSchedule(
            ids: Self.statsPollTargets(
                machines: machines, catalog: catalogProvider(), hasRunningCreate: createCoordinator.hasRunningOperations
            ),
            interval: Self.statsInterval
        )
        guard !schedule.isEmpty else {
            statsTask = nil
            return
        }
        statsTask = Task {
            for entry in schedule {
                if entry.delay > .zero { try? await Task.sleep(for: entry.delay) }
                guard !Task.isCancelled else { return }
                _ = try? await client.stats(id: entry.id)
            }
        }
    }
}
