package import CmuxNextCompat

/// The sidebar document store's projection memo (`SidebarDocStore.projectionCache`) as one small,
/// lossless memory consumer of the app's coordinator (Chrome's consumer contract,
/// base/memory_coordinator/memory_consumer.h; p07-memory.md task 054).
///
/// The memo is one entry and the next `projection(live:)` rebuilds it with one reducer `view` call, so
/// it takes no partial limit: a new limit frees nothing, and a release at critical drops the entry.
/// What the sidebar draws (`shown`) and the live list it was built over (`lastLiveOrder`, which `showsPinned`
/// projects over) stay, so the rebuild gives the same projection and the mirror's rows stay as shown.
@MainActor
final class SidebarDocProjectionMemory: MemoryConsumer {
    /// The consumer's name in the memory report.
    static let memoryConsumerName = "sidebar-doc-projection"
    /// Memory only, nothing lost and one reducer call to rebuild; one entry, so no partial limit.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .small, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: false)

    private weak var store: SidebarDocStore?
    private var registration: MemoryConsumerRegistration?

    /// Registers `store`'s memo with `registry`; the store keeps the consumer.
    init(store: SidebarDocStore, registry: any MemoryConsumerRegistry) {
        self.store = store
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// Frees nothing: the memo is one entry, which only a release at critical drops.
    func updateMemoryLimit(_ limit: MemoryLimit) {}

    /// Drops the memo at critical; the next `projection(live:)` builds it again.
    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if slice.limit.isCritical { store?.projectionCache = nil }
        return .done
    }

    /// The memo's own lists; its projection is the storage `shown` keeps.
    var memoryUsage: MemoryUsage? {
        guard let cache = store?.projectionCache else { return .empty }
        return MemoryUsage(footprintBytes: cache.ownedBytes, entries: 1)
    }
}

extension SidebarDocStore {
    /// Registers the projection memo with the app's memory coordinator (once; a later call replaces the
    /// registration). The composition root calls it when it makes the app's one store.
    ///
    /// - Parameter registry: The memory coordinator.
    package func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        projectionMemory = SidebarDocProjectionMemory(store: self, registry: registry)
    }
}
