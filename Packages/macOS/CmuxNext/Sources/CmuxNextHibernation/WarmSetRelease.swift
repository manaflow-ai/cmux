package import CmuxNextCompat

/// The terminal warm set, as ``WarmSetRelease`` sizes it (the App's `TabContentCache` over its
/// `SurfaceLedger`, the one LRU of hidden terminal surfaces).
@MainActor
package protocol WarmSetHost: AnyObject {
    /// How many hidden surfaces the LRU may keep now.
    var warmCapacity: Int { get }
    /// How many hidden surfaces the LRU keeps now (at most ``warmCapacity``).
    var warmHiddenCount: Int { get }
    /// How long the least recently hidden surface, the next one a smaller capacity closes, has been
    /// hidden; nil when the LRU keeps none.
    var leastRecentlyHiddenAge: Duration? { get }
    /// The budget the warm set comes down to (or goes up to): what `debug.surfaces` reports and what
    /// the last frames of closed surfaces are kept at.
    func warmBudgetDidChange(to capacity: Int)
    /// Sets the LRU's capacity; a smaller one closes the least recently hidden surfaces beyond it at
    /// once, keeping no last picture.
    ///
    /// - Returns: How many surfaces closed.
    func setWarmCapacity(_ capacity: Int) -> Int
}

/// The terminal warm set as a lossless consumer of the app's memory coordinator (p07-memory.md
/// task 096).
///
/// Chrome keeps hidden tabs' saved frames in one LRU, `components/viz/client/frame_eviction_manager.cc`,
/// which purges part of it at moderate pressure and all of it at critical. cmux's warm set is that LRU for
/// terminal surfaces, and its limit is the coordinator's: the warm set keeps `limit` of its normal capacity
/// (warning: the Memory Saver mode's share of 50 %, critical: 0). Chrome purges in the pressure listener's
/// turn; cmux closes one surface per release slice, on later frames, least recently hidden first, and
/// yields the rest of the slice to the consumers after it (``MemoryReleaseProgress/yield``).
///
/// A surface hidden less than ``workingSet`` ago is the warm set's working set (p07-memory.md section
/// 3.A): the release stops there, since the LRU's other surfaces were hidden later still.
@MainActor
package final class WarmSetRelease: MemoryConsumer {
    package static let memoryConsumerName = "terminal-warm-set"
    /// Lossless, memory only and cheap to rebuild (a surface comes back with a replay from the daemon's
    /// memory), so the policy scales it at warning as at critical.
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .high, isStateful: true, supportsMemoryLimit: true)
    /// Surfaces hidden this recently are never closed by a release (p07-memory.md section 3.A).
    package static let workingSet: Duration = .seconds(2)

    /// How many surfaces it closed for a smaller limit (tests).
    package private(set) var closes = 0
    /// The warm set's capacity at 100 % (`WarmSetBudget` at normal pressure, from physical memory).
    package let normalCapacity: Int
    /// The coordinator's limit.
    package private(set) var limit = MemoryLimit.default
    private weak var host: (any WarmSetHost)?
    private var registration: MemoryConsumerRegistration?

    /// Registers `host`'s warm set with `registry`; the host keeps the consumer.
    ///
    /// - Parameters:
    ///   - host: The warm set it sizes.
    ///   - normalCapacity: The warm set's capacity at 100 %.
    ///   - registry: The app's memory coordinator.
    package init(host: any WarmSetHost, normalCapacity: Int, registry: any MemoryConsumerRegistry) {
        self.host = host
        self.normalCapacity = max(normalCapacity, 0)
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// The capacity the limit sets: ``normalCapacity`` scaled by it.
    package var targetCapacity: Int { limit.scale(normalCapacity) }

    /// A larger target applies at once (nothing closes); a smaller one waits for the release slices
    /// that follow on later frames.
    package func updateMemoryLimit(_ limit: MemoryLimit) {
        self.limit = limit
        guard let host else { return }
        host.warmBudgetDidChange(to: targetCapacity)
        if targetCapacity > host.warmCapacity { _ = host.setWarmCapacity(targetCapacity) }
    }

    /// Closes the least recently hidden surface and returns ``MemoryReleaseProgress/yield`` while the
    /// warm set is over `slice.limit`; ``MemoryReleaseProgress/done`` once it is within it, or when the
    /// next surface to close is in the working set.
    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard let host else { return .done }
        let target = slice.limit.scale(normalCapacity)
        // Capacity no hidden surface fills goes at once: lowering it closes nothing.
        let filled = max(target, min(host.warmCapacity, host.warmHiddenCount))
        if filled < host.warmCapacity { _ = host.setWarmCapacity(filled) }
        guard host.warmCapacity > target else { return .done }
        if let age = host.leastRecentlyHiddenAge, age < Self.workingSet { return .done }
        closes += host.setWarmCapacity(host.warmCapacity - 1)
        return host.warmCapacity > target ? .yield : .done
    }

    /// Unknown: the host counts surfaces, not their bytes (`debug.surfaces` has the counts).
    package var memoryUsage: MemoryUsage? { nil }
}
