import CmuxNextCompat
import CmuxNextHibernation

// One lossy memory consumer of the app's coordinator, as Chrome's urgent page discarding policy
// (urgent_page_discarding_policy.cc: kLarge, kLossy, IsStateful::kNo), which acts when its limit
// reaches the critical threshold. The critical limit's release slice, a frame after the level
// change, runs one urgent pass; the owners' critical paces run the next ones (with
// `memoryUrgentDiscardRanking` that pass ranks tabs, chats and pages: `urgentPass()`).
// The level sets the timeout and the warning pace (p07-memory.md section 3.A).
extension BrowserHibernation: MemoryLevelConsumer {
    static let memoryConsumerName = "browser-hibernation"
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)

    /// The coordinator gives the limit first, so at critical the pass waits for the release slice.
    func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        pressureDidChange(level, replans: !memoryLimit.isCritical)
        onMemoryLevel?(level)
    }
    func updateMemoryLimit(_ limit: MemoryLimit) { memoryLimit = limit }

    /// At the critical limit, one urgent pass: with `memoryUrgentDiscardRanking` the first page of one
    /// ranking over tabs, chats and pages (``urgentPass()``), without it the probes of the tabs due now
    /// (each discard finishes on its own turn); then the planner's next look is armed.
    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard slice.limit.isCritical else { return .done }
        urgentPasses += 1
        if ranksUrgentDiscards { urgentPass() } else { replan() }
        refreshMemoryIfNeeded()
        return .done
    }

    /// Ranks every owner's hidden pages once and lets the first go (``UrgentDiscardRanker/run(_:)``):
    /// a browser tab through its probe, a chat after its wake state, a page at once. Every owner's own
    /// paced discards then wait one of its pace intervals.
    func urgentPass() {
        guard let cache else { return }
        lastUrgentPass = urgentRanker.run([self] + urgentDiscardOwners())
        for candidate in lastUrgentPass.discards {
            cache.trace(candidate.key, "discard (\(DiscardReason.urgent.rawValue), ranked \(candidate.kind.rawValue))")
        }
    }

    /// The last sampled memory of the hidden pages it could discard; nil before the first sample.
    var memoryUsage: MemoryUsage? {
        guard let cache, !memoryBytes.isEmpty else { return nil }
        let sampled = cache.lifecycle.keys(in: .mountedHidden).compactMap { memoryBytes[$0] }
        return MemoryUsage(footprintBytes: Int(clamping: sampled.reduce(0, +)), entries: sampled.count)
    }
}
