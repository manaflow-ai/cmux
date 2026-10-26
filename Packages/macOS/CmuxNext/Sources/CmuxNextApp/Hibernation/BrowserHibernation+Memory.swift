import CmuxNextCompat

// Browser hibernation as one lossy memory consumer of the app's memory coordinator
// (plans/cmux-next/chrome-parity/p07-memory.md, task 017).
//
// Chrome's urgent page discarding policy is a memory consumer with the traits kLarge, kLossy,
// kAsynchronous and IsStateful::kNo
// (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc). Browser
// hibernation registers the same way instead of subscribing to the kernel's pressure source
// itself, so the debug override and the kernel level reach it through the one coordinator. It
// paces its own discards (`HibernationPlanner.Pace`), so it takes the level and frees nothing in
// the coordinator's release slices.
extension BrowserHibernation: MemoryLevelConsumer {
    /// The consumer's name in the memory report and `debug.memory`.
    static let memoryConsumerName = "browser-hibernation"

    /// Large, lossy (a discarded page reloads), expensive to rebuild, released by its own planner
    /// rather than to a share of a limit.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)

    func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        pressureDidChange(level)
    }

    /// The level carries everything the planner needs (`memoryLevelDidChange(_:)`).
    func updateMemoryLimit(_ limit: MemoryLimit) {}

    /// The planner discards at its own pace when the level changes; a slice has nothing to free.
    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        .done
    }

    /// The last sampled memory of the hidden pages it could discard; nil before the first sample.
    var memoryUsage: MemoryUsage? {
        guard let cache, !memoryBytes.isEmpty else { return nil }
        var bytes: UInt64 = 0
        var pages = 0
        for key in cache.lifecycle.keys(in: .mountedHidden) {
            guard let sampled = memoryBytes[key] else { continue }
            bytes += sampled
            pages += 1
        }
        return MemoryUsage(footprintBytes: Int(clamping: bytes), entries: pages)
    }
}
