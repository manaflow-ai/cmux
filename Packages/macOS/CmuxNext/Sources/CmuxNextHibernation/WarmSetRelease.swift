package import CmuxNextCompat

/// The terminal warm set, as ``WarmSetRelease`` sizes it (the App's `TabContentCache` over its
/// `SurfaceLedger`, the one LRU of hidden terminal surfaces).
@MainActor
package protocol WarmSetHost: AnyObject {
    /// How many hidden surfaces the LRU keeps now.
    var warmCapacity: Int { get }
    /// The budget the warm set comes down to (or goes up to): what `debug.surfaces` reports and what
    /// the last frames of closed surfaces are kept at.
    func warmBudgetDidChange(to capacity: Int)
    /// Sets the LRU's capacity; a smaller one closes the least recently hidden surfaces beyond it at
    /// once, keeping no last picture.
    ///
    /// - Returns: How many surfaces closed.
    func setWarmCapacity(_ capacity: Int) -> Int
}

/// The terminal warm set as a consumer of the app's memory coordinator (p07-memory.md task 096).
///
/// Chrome keeps hidden tabs' saved frames in one LRU, `content/browser/renderer_host/frame_eviction_manager.cc`,
/// which purges part of it at moderate pressure and all of it at critical. cmux's warm set is that LRU for
/// terminal surfaces. Chrome purges in the pressure listener's turn; cmux closes one surface per release
/// slice, on later frames, least recently hidden first, so a fall to critical with 30 warm surfaces costs
/// 30 short frames instead of one long main turn.
///
/// The capacity per level stays `WarmSetBudget`'s (task 037 moves it to `SubsystemBudget`), so the level,
/// not the limit's percentage, sets the target. The traits are those of a lossless, memory-only consumer
/// that is cheap to rebuild (a surface comes back with its last frame shown at once and a replay from the
/// daemon's memory), which gives it release slices at warning as at critical, as Chrome's purge at
/// moderate pressure.
@MainActor
package final class WarmSetRelease: MemoryLevelConsumer {
    package static let memoryConsumerName = "terminal-warm-set"
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .high, isStateful: true, supportsMemoryLimit: true)

    /// How many surfaces it closed for a smaller budget (tests).
    package private(set) var closes = 0
    /// The capacity the level sets; the host's LRU comes down to it one surface per slice.
    package private(set) var targetCapacity: Int
    private weak var host: (any WarmSetHost)?
    private let capacities: (MemoryPressureLevel) -> Int
    private var registration: MemoryConsumerRegistration?

    /// Registers `host`'s warm set with `registry`; the host keeps the consumer.
    ///
    /// - Parameters:
    ///   - host: The warm set it sizes.
    ///   - registry: The app's memory coordinator.
    ///   - capacities: The warm set's capacity at each pressure level (from physical memory in the app).
    package init(host: any WarmSetHost, registry: any MemoryConsumerRegistry, capacities: @escaping (MemoryPressureLevel) -> Int) {
        self.host = host
        self.capacities = capacities
        targetCapacity = host.warmCapacity
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// The level sets the target. A larger one applies at once (nothing closes); a smaller one waits for
    /// the release slices that follow on later frames.
    package func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        targetCapacity = capacities(level)
        guard let host else { return }
        host.warmBudgetDidChange(to: targetCapacity)
        if targetCapacity > host.warmCapacity { _ = host.setWarmCapacity(targetCapacity) }
    }

    /// The level, which comes with each limit, sets the target (``memoryLevelDidChange(_:)``).
    package func updateMemoryLimit(_ limit: MemoryLimit) {}

    /// Closes the least recently hidden surface and returns ``MemoryReleaseProgress/more``, or returns
    /// ``MemoryReleaseProgress/done`` when the warm set is within its target. Each step lowers the LRU's
    /// capacity by one; a step that closes nothing (fewer hidden surfaces than the capacity) costs no
    /// close, so one call closes at most one surface in at most the old capacity's steps.
    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard let host else { return .done }
        while host.warmCapacity > targetCapacity {
            guard host.setWarmCapacity(host.warmCapacity - 1) > 0 else { continue }
            closes += 1
            return .more
        }
        return .done
    }

    /// Unknown: the host counts surfaces, not their bytes (`debug.surfaces` has the counts).
    package var memoryUsage: MemoryUsage? { nil }
}
